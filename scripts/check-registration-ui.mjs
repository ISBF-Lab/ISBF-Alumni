import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL(
    "../assets/javascripts/discourse/components/isbf-alumni-registration.gjs",
    import.meta.url
  ),
  "utf8"
);
const connectorSource = fs.readFileSync(
  new URL(
    "../assets/javascripts/discourse/connectors/academy-alumni-registration/isbf-alumni-registration.gjs",
    import.meta.url
  ),
  "utf8"
);
assert.match(
  connectorSource,
  /from "\.\.\/\.\.\/components\/isbf-alumni-registration"/
);
const logic =
  source
    .slice(0, source.indexOf("  <template>"))
    .replace(/^import .*;\r?\n/gm, "")
    .replace(/@tracked /g, "")
    .replace(/  @action\r?\n/g, "")
    .replace("export default class", "globalThis.Registration = class") + "}";
let handler;
const calls = [];
const context = {
  Component: class {
    willDestroy() {
      this.isDestroying = true;
    }
  },
  FormData,
  Date,
  encodeURIComponent,
  i18n: (key) => key,
  extractError: (error) => error.message,
  ajax: (url, options) => {
    calls.push({ url, options });
    return Promise.resolve().then(() => handler(url, options));
  },
};
vm.createContext(context);
vm.runInContext(logic, context);
const settle = async () => {
  for (let index = 0; index < 15; index++) {
    await Promise.resolve();
  }
};
handler = (url) =>
  url.endsWith("registration-config")
    ? {
        enabled: true,
        countries: [
          {
            code: "CN",
            regions: [
              { code: "GD", cities: [{ code: "GZ", name: "Guangzhou" }] },
            ],
          },
        ],
      }
    : { verified: false };
const form = new context.Registration();
await settle();
assert.equal(form.step, "email");
assert.equal(form.form.visible, false);
form.form = {
  ...form.form,
  country_code: "CN",
  region_code: "GD",
  city_code: "GZ",
  city_name: "Guangzhou",
};
form.update("region_code", { target: { value: "BJ" } });
assert.equal(form.form.city_code, "");
assert.equal(form.form.city_name, "");
form.email = "person@example.test";
handler = (url) =>
  url.endsWith("verify-email")
    ? { email: "person@example.test", application: null }
    : {};
await form.sendCode({ preventDefault() {} });
assert.equal(form.step, "code");
form.code = "123456";
await form.verify({ preventDefault() {} });
assert.equal(form.step, "application");
assert.equal(form.code, "");
form.form.real_name = "Applicant";
form.proofs = [{ id: 1, bytes: 900000 }];
handler = () => {
  throw new Error("Network failed");
};
await form.submit({ preventDefault() {} });
assert.equal(form.form.real_name, "Applicant");
assert.equal(form.proofs.length, 1);
assert.equal(form.error, "Network failed");
handler = () => ({ application: { status: "pending" } });
await form.submit({ preventDefault() {} });
assert.equal(form.editable, false);
assert.equal(calls.at(-1).options.data.proof_ids[0], 1);
const beforeInvalidUpload = calls.length;
await form.upload({
  target: { files: [{ name: "proof.exe", size: 100 }], value: "" },
});
assert.equal(calls.length, beforeInvalidUpload);
assert.equal(form.error, "isbf_alumni.registration.proof_invalid");
await form.upload({
  target: { files: [{ name: "proof.heic", size: 10000001 }], value: "" },
});
assert.equal(calls.length, beforeInvalidUpload);
form.busy = true;
await form.resend();
assert.equal(
  calls.length,
  beforeInvalidUpload,
  "Busy state prevents duplicate requests"
);
form.busy = false;
form.application = { status: "rejected", proofs: [{ id: 1 }] };
assert.equal(form.editable, true);
const count = calls.length;
await form.remove(form.proofs[0]);
assert.equal(
  calls.length,
  count,
  "Existing submitted evidence is detached locally, never deleted"
);
form.willDestroy();
assert.equal(form.email, "");
assert.equal(form.proofs.length, 0);
assert.equal(form.form.real_name, "");
process.stdout.write(
  "Alumni registration: email verification, dependent city, opt-in, failure retention, approval states, private evidence preservation and cleanup passed."
);
