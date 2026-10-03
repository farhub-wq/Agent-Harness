// 0001_baseline —— 把 langgraph_store 的两个索引显式化。
//
// 这两个索引**现在就已经存在**：src/api_view/mongodb_store.py 的
// MongoDBStore.__init__ 里那两行 create_index，每次后端进程启动都会执行一次。
// 所以在一个已经在跑的库上，这个迁移跑出来的效果是「什么都没变」—— 这是刻意的。
//
// 那它为什么还要存在：
//   1. 一个**从没被执行过**的迁移框架，和一个能用的迁移框架，在出事之前长得
//      一模一样。0001 是这条路径上第一个真的会被执行、能被验证的东西 ——
//      它在 PR 门禁里真跑一遍，往后每个迁移都照着它的形状写。
//   2. 索引属于**数据库的结构**，不属于某一次进程启动。留在 __init__ 里的后果是
//      「这个库现在应该有哪些索引」这个问题没有一个地方能回答 —— 它散在代码里，
//      而且只在进程启动的那一刻为真。
//
// 注意：不要顺手把 checkpointing_db 的索引也搬进来。那是 langgraph-checkpoint
// 库自己建的，复制一份到迁移里，等库升级换了索引定义就会撞 IndexOptionsConflict
// （见 migrations/README.md 的规则 7）。

if (!process.env.MONGODB_DB_NAME) {
  throw new Error(
    "MONGODB_DB_NAME 没设 —— 迁移不知道要改哪个库。" +
    "它是 deploy/.env 里的一行，由 compose 的 env_file 注入 mongo 容器；" +
    "先确认那一行在、并且 mongo 容器是（重新）起过的。"
  );
}

// 不要叫 `db`：mongosh 的求值上下文里 `db` 已经是一个全局，同名 const 在部分
// 版本上会直接报重复声明，而那看起来像"迁移文件里的语法错误"，方向全错。
const appDb = db.getSiblingDB(process.env.MONGODB_DB_NAME);
const store = appDb.getCollection("langgraph_store");

// 与 mongodb_store.py 的两行逐字对应（含 MongoDB 自动生成的索引名 —— 显式写出
// 来是为了让「迁移建的」与「代码建的那个」被证明是同一个索引，而不是两个同义
// 不同名的东西）。
//
// createIndex 在 spec 与 options 完全相同时是幂等的：它返回已有的索引名，不改
// 任何东西。这条只对**完全一致**成立 —— 同名但 options 不同会抛
// IndexOptionsConflict，那正是我们想让它抛的（说明代码与迁移已经漂了）。
store.createIndex({ namespace: 1, key: 1 }, { unique: true, name: "namespace_1_key_1" });
store.createIndex({ updated_at: 1 }, { name: "updated_at_1" });

print("0001_baseline: " + process.env.MONGODB_DB_NAME + ".langgraph_store 的两个索引已就位");
