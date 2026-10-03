#!/usr/bin/env bash
# 数据库备份 + restore 自检。发布前由 deploy/cd/deploy.sh 的 cd_backup() 调用，
# 也可以单独跑（演练、排查、CI）。
#
#   bash deploy/dr/backup.sh                     备份 → 自检 → 剪枝 → 外推
#   bash deploy/dr/backup.sh --verify <目录>      只对一个已有备份跑自检
#   bash deploy/dr/backup.sh --prune             只跑保留策略
#   bash deploy/dr/backup.sh --list              列出已有备份
#
# 环境变量：
#   CD_BACKUP_DIR        备份根目录，默认 /var/backups/erp-agent
#   CD_BACKUP_KEEP       保留份数，默认 7
#   CD_BACKUP_VERSION    目录名里的版本标签
#   CD_BACKUP_GIT_SHA    记进清单的 commit
#   CD_BACKUP_SKIP_VOLUME=1   跳过 download-data 卷
#   CD_BACKUP_NO_OFFSITE=1    跳过外推（CI 用）
#   BACKUP_RESULT_FILE   写 DB_DUMP= / DB_DUMP_SHA256= 两行的地方（给调用方读）
#
# ---------------------------------------------------------------- 为什么是「枚举数据库」
# 这套应用用了**两个** MongoDB 库，而配置里只看得到一个：
#   erp_agent          —— 应用自己配的（MONGODB_DB_NAME）
#   checkpointing_db   —— langgraph-checkpoint-mongodb 的**库默认值**。
#                         src/api_view/agent_loader.py 构造 MongoDBSaver 时没传
#                         db_name，于是会话状态与 HITL 待审批状态全落在这里。
# checkpointing_db 这个名字**不出现在任何配置或应用代码里**。所以一个「按
# MONGODB_URI 里的库名 dump」的备份会把会话历史整段丢掉，而且不会报错 ——
# 备份文件是好的、自检也是过的，只是少了一个库。
#
# 因此库清单必须**运行时枚举**，不能来自配置。这也是这里不用单个全库 archive
# 的原因：`--uri` 里带库名时 mongodump 到底按不按它限定范围，我没有把握，而
# 「没把握」在这里等于「可能少备份一个库」。逐库显式 --db 把这个不确定性删掉。
#
# ---------------------------------------------------------------- 为什么自检是硬门槛
# 没验过的备份是心理安慰，不是备份。自检的做法是把 dump 真的恢复进一个一次性
# mongo 容器，逐集合比对文档数 —— 不是数集合个数。因为空库和「恢复成功但内容
# 为空」长得一模一样（3 个急切建的集合、0 条文档），集合数量证明不了任何事。
#
# 比对的是「恢复库 vs 清单」，**不是**「恢复库 vs 活着的源库」：源库一直在被
# 应用写，拿它当基准会得到随机的失败。清单记的是 dump 那一刻的真值。
set -euo pipefail

DR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../cd/lib.sh
source "$DR_DIR/../cd/lib.sh"
# shellcheck source=lib-dr.sh
source "$DR_DIR/lib-dr.sh"

CD_BACKUP_DIR="${CD_BACKUP_DIR:-/var/backups/erp-agent}"
CD_BACKUP_KEEP="${CD_BACKUP_KEEP:-7}"
CD_RESTORE_MEMORY="${CD_RESTORE_MEMORY:-512m}"
CD_RESTORE_CACHE_GB="${CD_RESTORE_CACHE_GB:-0.25}"
CD_RESTORE_TIMEOUT="${CD_RESTORE_TIMEOUT:-90}"

usage() { sed -n '2,18p' "$0" >&2; }

# ---------------------------------------------------------------- 基础
# dr_valid_name / dr_mongo_image / dr_assert_mongo_up / dr_mongo_eval 都在
# deploy/dr/lib-dr.sh —— 它们同时也是迁移器要用的，「怎么跟 mongo 说话」只留一份。

# ---------------------------------------------------------------- 枚举
dr_discover_dbs() {
    dr_mongo_eval '
        db.adminCommand({listDatabases:1}).databases
          .map(d => d.name)
          .filter(n => ["admin","local","config"].indexOf(n) === -1)
          .sort()
          .forEach(n => print(n));
    ' | tr -d '\r' | grep -v '^[[:space:]]*$' || true
}

# 输出 "collection<TAB>count" 逐行。用 countDocuments 而不是
# estimatedDocumentCount：后者读元数据，在 dump 刚写完这种时序上给出的数可能
# 不准，而这里要的正是「准」。
dr_collections_of() {
    local db="$1"
    dr_mongo_eval '
        const d = db.getSiblingDB("'"$db"'");
        d.getCollectionNames().sort().forEach(n =>
            print(n + "\t" + d.getCollection(n).countDocuments({})));
    ' | tr -d '\r' | grep -v '^[[:space:]]*$' || true
}

# 把 dump **前后**两次读数合成一个区间：`db<TAB>coll<TAB>最少<TAB>最多`。
#
# 为什么不是「dump 之后读一次，然后要求恢复出来的条数等于它」——
# 生产栈在发布期间**仍在服务**，备份窗口里一定有人在写。dump 完成之后再读计数，
# 拿到的可能是 N+1，而 dump 里只有 N。等值比较会把一个完全健康的备份判成坏的，
# 而这是发布路径上的硬门槛 —— 结果是每次有人正在聊天时发布都会中止。
# 反过来（先读、后 dump）也一样会漏。
#
# 区间是这件事唯一诚实的表达：这个集合在这段时间里是 3 到 5 条，dump 里落在
# 区间内就算对。区间外的两种情形才是真问题 —— 少于下限是丢数据，多于上限说明
# 恢复进了不属于这份 dump 的东西。
#
# 只出现过一次的集合（dump 期间被建/被删）下限记 0：它到底被 dump 到多少，
# 我们并不知道，不能假装知道。
dr_merge_counts() {
    local db="$1" c0="$2" c1="$3"
    { sed 's/^/0\t/' "$c0"; sed 's/^/1\t/' "$c1"; } \
    | awk -F'\t' -v db="$db" '
        {
            src = $1 + 0; coll = $2; n = $3 + 0
            if (!(coll in lo)) { lo[coll] = n; hi[coll] = n; order[++k] = coll }
            else { if (n < lo[coll]) lo[coll] = n; if (n > hi[coll]) hi[coll] = n }
            seen0[coll] += (src == 0)
            seen1[coll] += (src == 1)
        }
        END {
            for (i = 1; i <= k; i++) {
                c = order[i]
                if (!(seen0[c] && seen1[c])) lo[c] = 0
                printf "%s\t%s\t%d\t%d\n", db, c, lo[c], hi[c]
            }
        }
    ' | sort -t"$(printf '\t')" -k2,2
}

# ---------------------------------------------------------------- dump
dr_dump_db() {
    local db="$1" out="$2"
    # --archive 不带 =文件名 时写 stdout，进度与报错走 stderr。
    # **不**在命令行上出现凭据：$MONGODB_URI 由容器自己的 shell 展开。
    if ! cd_compose exec -T -e BK_DUMP_DB="$db" "$CD_MONGO_SERVICE" sh -c \
            'mongodump --uri="$MONGODB_URI" --db="$BK_DUMP_DB" --archive --gzip' > "$out"; then
        warn "mongodump $db 失败"
        return 1
    fi
    if [ ! -s "$out" ]; then
        warn "mongodump $db 产出了空文件"
        return 1
    fi
    return 0
}

# download-data 卷里是用户生成的报告文件。Mongo 里**没有**它们的索引 ——
# 文件名只作为文本存在于消息里，所以丢了之后会话记录还在、每个下载链接都变成
# 死链，且没有任何办法重建（文件是模型在沙箱里生成的）。deploy/README.md 原先
# 写「只有 Mongo 需要备份」是错的，这里是修正。
dr_dump_volume() {
    local out="$1" img="$2" vol="${PROJECT}_download-data"
    if ! docker volume inspect "$vol" >/dev/null 2>&1; then
        info "卷 $vol 不存在，跳过（本机还没生成过任何下载文件）"
        return 0
    fi
    # 用已经在本机的镜像跑 tar，不额外拉一个 alpine —— 生产机拉新镜像要过
    # 代理/镜像源，为一次 tar 引入这个依赖不划算。
    if ! docker run --rm -v "$vol":/d:ro "$img" tar -czf - -C /d . > "$out" 2>/dev/null; then
        warn "打包卷 $vol 失败"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- 清单
# 格式刻意做成「一行一个事实、空格分隔」—— 既能人读，又能 while read 解析，
# 还便于事后手工核对「到底备份了哪几个库」。恢复自检逐条比对本文件。
dr_write_manifest() {
    local dir="$1" version="$2" sha="$3"
    # 必须分行：`local a="$1" b="$a/x"` 里 $a 是在 local 赋值**之前**展开的，
    # set -u 下当场 unbound（实测踩到过）。
    local manifest="$dir/manifest.txt"
    local f db coll lo hi vf

    {
        printf '# erp-agent 备份清单。恢复自检逐条比对本文件，不要手改。\n'
        printf '# 行格式：KIND 字段…（空格分隔）\n'
        printf '# COLL 的两个数字是 dump **前后**两次读到的条数区间（见 counts.tsv）。\n'
        printf 'META version %s\n'    "$version"
        printf 'META created_at %s\n' "$(date -Iseconds)"
        printf 'META host %s\n'       "$(hostname)"
        printf 'META git_sha %s\n'    "${sha:--}"

        for f in "$dir"/*.archive.gz; do
            [ -f "$f" ] || continue
            db="$(basename "$f" .archive.gz)"
            dr_valid_name "$db" || { warn "库名 '$db' 形状可疑，拒绝写进清单"; return 1; }
            printf 'DB %s %s %s %s\n' "$db" "$(basename "$f")" \
                "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")"
        done

        # 逐集合的期望区间由 dr_run_backup 在 dump 前后各读一次后合成。
        # 这里不再去问活库 —— 那份读数会和 dump 的内容错位（见 dr_merge_counts）。
        if [ -f "$dir/counts.tsv" ]; then
            while IFS=$'\t' read -r db coll lo hi; do
                [ -n "$coll" ] || continue
                dr_valid_name "$db" && dr_valid_name "$coll" \
                    || { warn "库/集合名 '$db.$coll' 形状可疑，拒绝写进清单"; return 1; }
                printf 'COLL %s %s %s %s\n' "$db" "$coll" "$lo" "$hi"
            done < "$dir/counts.tsv"
        fi

        vf="$dir/download-data.tar.gz"
        if [ -f "$vf" ]; then
            printf 'VOLUME %s %s %s %s %s\n' \
                "${PROJECT}_download-data" "$(basename "$vf")" \
                "$(sha256sum "$vf" | cut -d' ' -f1)" "$(stat -c%s "$vf")" \
                "$(tar -tzf "$vf" 2>/dev/null | grep -c . || true)"
        fi
    } > "$manifest"

    sha256sum "$manifest" | cut -d' ' -f1
}

# ---------------------------------------------------------------- 恢复自检
dr_rm_container() { docker rm -f "$1" >/dev/null 2>&1 || true; }

dr_start_restore() {
    local name="$1" img="$2" end
    dr_rm_container "$name"
    # --network none：它不需要跟任何东西通信，一个能发起的连接就是一个多余的面。
    # 内存与 WiredTiger 缓存都必须显式限死：这台机器只有 3.6G，而 WiredTiger
    # 默认吃宿主机内存的 50% —— 一个「只用来验一下」的容器把生产 MongoDB 挤到
    # OOM 是这类脚本最讽刺的失败方式。
    if ! docker run -d --rm --name "$name" --network none \
            --memory "$CD_RESTORE_MEMORY" \
            "$img" --wiredTigerCacheSizeGB "$CD_RESTORE_CACHE_GB" >/dev/null; then
        warn "起一次性 mongo 容器失败（镜像 $img 在本机吗？）"
        return 1
    fi
    end=$((SECONDS + CD_RESTORE_TIMEOUT))
    while [ "$SECONDS" -lt "$end" ]; do
        if docker exec "$name" mongosh --quiet --eval \
                'print(db.adminCommand({ping:1}).ok)' 2>/dev/null | grep -q 1; then
            return 0
        fi
        sleep 2
    done
    warn "一次性 mongo 容器 ${CD_RESTORE_TIMEOUT}s 内没起来"
    docker logs "$name" 2>&1 | tail -20 >&2 || true
    return 1
}

# 比对「恢复出来的库」与清单。0 = 通过。
dr_compare() {
    local name="$1" dir="$2" rc=0
    local manifest="$dir/manifest.txt"   # 分行：见 dr_write_manifest 的说明
    local declared actual db coll want got bad=0
    local vname vfile vsha vbytes ventries
    local dbfile sha want_sha

    # 0) 文件完整性。清单里记了每个 archive 的 sha256，比对它是为了让那些字段
    #    不是装饰：半截写入、断电截断、磁盘坏块都会在这里现形 —— 而它们恰恰能
    #    让 mongorestore「成功但少恢复了一部分」，那是最难事后发现的一类损坏。
    while read -r _ db dbfile want_sha _; do
        if [ ! -f "$dir/$dbfile" ]; then
            warn "自检失败：清单记了 $dbfile，文件不在"
            rc=1
            continue
        fi
        sha="$(sha256sum "$dir/$dbfile" | cut -d' ' -f1)"
        if [ "$sha" != "$want_sha" ]; then
            warn "自检失败：$dbfile 的 sha256 与清单不符（被截断或改过？）"
            warn "  清单 $want_sha"
            warn "  实际 $sha"
            rc=1
        fi
    done < <(grep '^DB ' "$manifest" || true)

    # 1) 恢复出来的用户库集合，必须与清单里的 DB 行**完全一致**。
    #    这是「备份漏了一个库」唯一能被抓住的地方：只比对清单里写了的条目，
    #    漏写的那一行不会有任何表现，而漏库恰恰是这次最要紧的失效模式。
    declared="$(sed -n 's/^DB \([^ ]*\) .*/\1/p' "$manifest" | sort)"
    actual="$(docker exec "$name" mongosh --quiet --eval '
        db.adminCommand({listDatabases:1}).databases
          .map(d => d.name)
          .filter(n => ["admin","local","config"].indexOf(n) === -1)
          .sort()
          .forEach(n => print(n));
    ' | tr -d '\r' | grep -v '^[[:space:]]*$' | sort || true)"

    if [ "$declared" != "$actual" ]; then
        warn "自检失败：恢复出来的库与清单不一致"
        diff <(printf '清单：\n%s\n' "$declared") \
             <(printf '恢复：\n%s\n' "$actual") | sed 's/^/       /' >&2 || true
        rc=1
    else
        info "库集合一致：$(printf '%s' "$declared" | tr '\n' ' ')"
    fi

    # 2) 逐集合比文档数。比的是**区间**，理由见 dr_merge_counts：dump 窗口里
    #    生产还在写，等值比较会在有人正用着系统时把健康备份判成坏的。
    #    恢复后整个集合不存在时 countDocuments 返回 0 —— 只有区间下限是 0 才
    #    通过，所以「空集合在 restore 后不出现」这个 archive 细节不会误报，
    #    而「清单记着 5 条、恢复后没了」会照常失败。
    while read -r _ db coll lo hi; do
        got="$(docker exec "$name" mongosh --quiet --eval \
            'print(db.getSiblingDB("'"$db"'").getCollection("'"$coll"'").countDocuments({}))' \
            2>/dev/null | tr -d '\r' | tail -1)"
        case "${got:-}" in ''|*[!0-9]*) got=0 ;; esac
        if [ "$got" -lt "$lo" ] || [ "$got" -gt "$hi" ]; then
            warn "自检失败：$db.$coll 清单记 $lo..$hi 条，恢复出来 $got"
            bad=$((bad + 1))
        fi
    done < <(grep '^COLL ' "$manifest" || true)

    # 每个库都必须有 COLL 行。少了 counts.tsv 的话上面那个循环一条都不跑 ——
    # 自检会「全部通过」，而那等于把整个逐集合比对悄悄关掉了。
    local what
    while IFS= read -r what; do
        grep -q "^COLL $what " "$manifest" \
            || { warn "自检失败：库 $what 在清单里一条 COLL 都没有（counts.tsv 丢了？）"; rc=1; }
    done < <(grep '^DB ' "$manifest" | cut -d' ' -f2)

    if [ "$bad" -gt 0 ]; then
        warn "自检失败：$bad 个集合的文档数落在期望区间之外"
        rc=1
    elif [ "$rc" -eq 0 ]; then
        info "逐集合文档数一致（$(grep -c '^COLL ' "$manifest" || true) 个集合）"
    fi

    # 3) 卷：只验它可读、条目数与清单相符。完整解开比对成本不成比例 ——
    #    真正的恢复验证交给 restore-drill.sh。
    while read -r _ vname vfile vsha vbytes ventries; do
        if [ ! -f "$dir/$vfile" ]; then
            warn "自检失败：清单记了卷 $vname，但 $vfile 不在"
            rc=1
            continue
        fi
        if [ "${ventries:-0}" = "0" ] && tar -tzf "$dir/$vfile" 2>/dev/null | grep -q .; then
            warn "自检失败：卷 $vname 的实际条目数与清单记的 0 不符"
            rc=1
        fi
    done < <(grep '^VOLUME ' "$manifest" || true)

    return "$rc"
}

dr_verify() {
    local dir="$1" img name rc=0 f db
    local manifest="$dir/manifest.txt"   # 分行：见 dr_write_manifest 的说明
    [ -f "$manifest" ] || { warn "找不到 $manifest"; return 1; }

    img="$(dr_mongo_image)"
    log "恢复自检（一次性容器，镜像 $img，内存上限 $CD_RESTORE_MEMORY）"

    name="erp-restorecheck-$$"
    if ! dr_start_restore "$name" "$img"; then
        dr_rm_container "$name"
        return 1
    fi

    for f in "$dir"/*.archive.gz; do
        [ -f "$f" ] || continue
        db="$(basename "$f" .archive.gz)"
        dr_valid_name "$db" || { warn "库名 '$db' 形状可疑，拒绝恢复"; rc=1; continue; }
        if ! docker exec -i "$name" mongorestore --archive --gzip --drop --quiet < "$f"; then
            warn "mongorestore $db 失败"
            rc=1
        fi
    done

    [ "$rc" -eq 0 ] && { dr_compare "$name" "$dir" || rc=1; }

    dr_rm_container "$name"
    return "$rc"
}

# ---------------------------------------------------------------- 保留策略
# 剪枝在**新建之前**跑。绝不删状态文件引用的那两份：那是回滚的真值源，
# 删了就等于把「能不能滚回去」交给运气。
dr_prune() {
    local keep="${CD_BACKUP_KEEP:-7}" protected="" d f n=0 removed=0
    local -a all=()
    [ -d "$CD_BACKUP_DIR" ] || return 0

    for f in "$CD_STATE_FILE" "$CD_PREV_FILE"; do
        [ -f "$f" ] || continue
        d="$(cd_state_get "$f" DB_DUMP 2>/dev/null || true)"
        [ -n "$d" ] && protected="$protected $(basename "$d")"
    done

    while IFS= read -r d; do
        [ -n "$d" ] && all+=("$d")
    done < <(find "$CD_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        2>/dev/null | sort -r)

    for d in ${all[@]+"${all[@]}"}; do
        n=$((n + 1))
        [ "$n" -le "$keep" ] && continue
        case " $protected " in
            *" $d "*) info "保留 $d（状态文件引用中，不剪）"; continue ;;
        esac
        rm -rf "${CD_BACKUP_DIR:?}/$d"
        removed=$((removed + 1))
    done
    [ "$removed" -gt 0 ] && info "剪掉 $removed 份旧备份（保留最近 $keep 份 + 状态文件引用的）"
    return 0
}

# ---------------------------------------------------------------- 外推
# 实现在 commit 2（OSS）。这里刻意做成一个**显式的告警**而不是静默成功 ——
# 「同盘不是备份」这条如果被代码悄悄跳过，等于没有。
#
# 外推的**结果**由 offsite.sh 自己写进备份目录的 offsite.status（它才是唯一知道
# 事情办成了没有的一方，见那里的 dr_offsite_mark）。这里只管三件它管不到的事。
dr_offsite() {
    local dir="$1" script="$DR_DIR/offsite.sh"

    if [ "${CD_BACKUP_NO_OFFSITE:-0}" = "1" ]; then
        info "跳过外推（CD_BACKUP_NO_OFFSITE=1）"
        dr_offsite_mark "$dir" skipped "CD_BACKUP_NO_OFFSITE=1（CI 或演练）"
        return 0
    fi
    if [ ! -f "$script" ]; then
        warn "外推尚未实现：这份备份与生产在**同一块磁盘**上。"
        warn "  磁盘坏掉或实例被释放时它一起消失。见 deploy/dr/README.md。"
        dr_offsite_mark "$dir" skipped "没有 $script"
        return 0
    fi

    bash "$script" "$dir"
}

# ---------------------------------------------------------------- 主体
dr_run_backup() {
    local version="${CD_BACKUP_VERSION:-unknown}"
    local sha="${CD_BACKUP_GIT_SHA:-}"
    local stamp dir dbs db img mhash total

    # 定时备份（erp-agent-backup.timer）设这个环境变量：**一次发布正在进行时跳过
    # 本轮**。理由是这台机器只有 2 核 3.6G，而备份要起一个 512m 的一次性 mongo 做
    # 恢复自检 —— 和一次发布撞上的后果是把生产挤到 OOM，而发布那条路上的备份本来
    # 就是发布的一部分，不能因为「有 pending」就跳过它自己，所以这个守卫必须是
    # 有条件开启的。跳过不是失败：24 小时后还有一轮，而那一轮之后紧接着的心跳会
    # 如实报出备份有多旧。
    if [ "${CD_BACKUP_SKIP_IF_BUSY:-0}" = "1" ] && cd_deploy_in_flight; then
        info "有一次发布正在进行 —— 定时备份本轮跳过（不与发布抢 mongodump）"
        return 0
    fi

    mkdir -p "$CD_BACKUP_DIR"
    cd_assert_disk 3
    dr_assert_mongo_up || return 1

    dr_prune

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    dir="$CD_BACKUP_DIR/$stamp-$version"

    dbs="$(dr_discover_dbs)"
    if [ -z "$dbs" ]; then
        warn "一个业务库都没枚举到 —— 只有 admin/local/config。"
        warn "  这通常意味着连不上 Mongo 或权限不足，不是「确实没数据」。"
        return 1
    fi
    log "备份到 $dir"
    info "枚举到 $(printf '%s\n' "$dbs" | grep -c .) 个库：$(printf '%s' "$dbs" | tr '\n' ' ')"

    mkdir -p "$dir"
    : > "$dir/counts.tsv"
    for db in $dbs; do
        dr_valid_name "$db" || { warn "库名 '$db' 形状可疑，拒绝 dump"; rm -rf "$dir"; return 1; }
        info "dump $db"
        # 前后各读一次，夹住 dump 窗口 —— 生产栈此刻仍在服务，区间是唯一诚实的
        # 期望值（见 dr_merge_counts）。
        dr_collections_of "$db" > "$dir/.counts.before"
        dr_dump_db "$db" "$dir/$db.archive.gz" || { rm -rf "$dir"; return 1; }
        dr_collections_of "$db" > "$dir/.counts.after"
        dr_merge_counts "$db" "$dir/.counts.before" "$dir/.counts.after" >> "$dir/counts.tsv"
    done
    rm -f "$dir/.counts.before" "$dir/.counts.after"

    if [ "${CD_BACKUP_SKIP_VOLUME:-0}" != "1" ]; then
        img="$(dr_mongo_image)"
        dr_dump_volume "$dir/download-data.tar.gz" "$img" || { rm -rf "$dir"; return 1; }
    fi

    if ! mhash="$(dr_write_manifest "$dir" "$version" "$sha")"; then
        warn "写清单失败，放弃这份备份"
        rm -rf "$dir"
        return 1
    fi

    if ! dr_verify "$dir"; then
        warn "备份自检未通过 —— 这份 dump 不能算备份，发布中止"
        warn "  目录留在 $dir 供排查（下次剪枝会收走它）"
        return 1
    fi

    total="$(du -sh "$dir" | cut -f1)"
    info "备份完成：$dir（$total）"

    dr_offsite "$dir" || return 1

    if [ -n "${BACKUP_RESULT_FILE:-}" ]; then
        {
            printf 'DB_DUMP=%s\n' "$dir"
            printf 'DB_DUMP_SHA256=%s\n' "$mhash"
        } > "$BACKUP_RESULT_FILE"
    fi
    return 0
}

# ---------------------------------------------------------------- 入口
ACTION=backup
ARG_DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --verify)     ACTION=verify; ARG_DIR="${2:-}"; shift 2 ;;
        --prune)      ACTION=prune; shift ;;
        --no-offsite) CD_BACKUP_NO_OFFSITE=1; shift ;;
        --list)
            [ -d "$CD_BACKUP_DIR" ] || { echo "（还没有任何备份：$CD_BACKUP_DIR）"; exit 0; }
            ls -1 "$CD_BACKUP_DIR" | sed 's/^/  /'
            exit 0
            ;;
        -h|--help)    usage; exit 0 ;;
        *)            warn "未知参数 '$1'"; usage; exit 2 ;;
    esac
done

[ -n "${CD_ENV:-}" ] || cd_load_env "${CD_ENV_NAME:-production}"

case "$ACTION" in
    verify)
        [ -n "$ARG_DIR" ] || { usage; exit 2; }
        cd_assert_tools >/dev/null
        dr_verify "$ARG_DIR"
        ;;
    prune)  dr_prune ;;
    backup) dr_run_backup ;;
esac
