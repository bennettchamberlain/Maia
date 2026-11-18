import assert from "node:assert/strict";
import test from "node:test";
import { accountLogin, fillPathParams } from "./path_params.mjs";

test("a GitHub connection name is the login", () => {
  assert.equal(accountLogin({ name: "bennettchamberlain" }), "bennettchamberlain");
  assert.equal(accountLogin({ name: "Bennett Chamberlain" }), "");
  assert.equal(accountLogin({ username: "@bennettchamberlain" }), "bennettchamberlain");
});

test("username in the query or on the connection fills the path", () => {
  const fromQuery = fillPathParams(
    "/users/{{username}}/repos",
    {},
    { username: "bennettchamberlain/" },
    {},
    { name: "someone-else" },
  );
  assert.equal(fromQuery.username, "bennettchamberlain");

  const fromConnection = fillPathParams(
    "/users/{{username}}/repos",
    {},
    {},
    {},
    { platform: "github", name: "bennettchamberlain" },
  );
  assert.equal(fromConnection.username, "bennettchamberlain");
});
