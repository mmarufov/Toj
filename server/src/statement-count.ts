import type { SQL } from "bun";

export type CountedSQL = { sql: SQL; calls: () => number; reset: () => void };

/** Counts every statement issued through `sql`, including inside `sql.begin` transactions. */
export function countStatements(base: SQL): CountedSQL {
  let calls = 0;
  const wrap = (target: any): any => new Proxy(target, {
    apply(fn, _thisArg, args) {
      calls += 1;
      return Reflect.apply(fn, fn, args);
    },
    get(object, property) {
      const value = Reflect.get(object, property);
      if (property === "begin") {
        return (...args: any[]) => {
          const callback = args.pop();
          return object.begin(...args, (tx: SQL) => callback(wrap(tx)));
        };
      }
      if (property === "unsafe") {
        return (...args: any[]) => {
          calls += 1;
          return value.apply(object, args);
        };
      }
      return typeof value === "function" ? value.bind(object) : value;
    },
  });
  return { sql: wrap(base), calls: () => calls, reset: () => { calls = 0; } };
}
