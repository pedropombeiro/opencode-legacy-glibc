console.log("LD_LIBRARY_PATH:", JSON.stringify(process.env.LD_LIBRARY_PATH));
console.log("LD_PRELOAD:", JSON.stringify(process.env.LD_PRELOAD));
console.log("process.execPath:", process.execPath);

var cp = require("child_process");
try {
  var out = cp.execSync("/bin/sh -c 'echo child_ok'", { encoding: "utf8" });
  console.log("child spawn:", out.trim());
} catch(e) {
  console.log("child spawn FAILED:", e.message.split("\n")[0]);
}
