import assert from "node:assert/strict";
import test from "node:test";
import { rankActions } from "./actions.mjs";

test("a read question skips writes", () => {
  const ranked = rankActions(
    [
      { _id: "create", method: "POST" },
      { _id: "list", method: "GET" },
    ],
    "what is in my github account",
  );
  assert.deepEqual(ranked.map((action) => action._id), ["list"]);
});

test("a write question keeps the write", () => {
  const ranked = rankActions(
    [
      { _id: "create", method: "POST" },
      { _id: "list", method: "GET" },
    ],
    "create an issue",
  );
  assert.equal(ranked[0]._id, "create");
});
