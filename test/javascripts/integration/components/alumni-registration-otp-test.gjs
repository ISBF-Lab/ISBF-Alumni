import { click, fillIn, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import AlumniRegistration from "discourse/plugins/isbf-alumni/discourse/components/isbf-alumni-registration";

module("Alumni registration | animated OTP", function (hooks) {
  setupRenderingTest(hooks);

  hooks.beforeEach(function () {
    pretender.get("/isbf/alumni/registration-config", () =>
      response({ enabled: true, countries: [] })
    );
    pretender.get("/isbf/alumni/applications/current", () =>
      response({ verified: false })
    );
    pretender.post("/isbf/alumni/applications/email", () =>
      response({ success: "OK" })
    );
  });

  async function enterCodeStep() {
    await render(<template><AlumniRegistration /></template>);
    await fillIn(
      ".isbf-alumni-registration input[type='email']",
      "graduate@example.invalid"
    );
    await click(".isbf-alumni-registration button[type='submit']");
  }

  test("verifies a complete code once and opens the application", async function (assert) {
    let requests = 0;
    pretender.post("/isbf/alumni/applications/verify-email", (request) => {
      requests++;
      assert.strictEqual(
        new URLSearchParams(request.requestBody).get("code"),
        "001234"
      );
      return response({ email: "graduate@example.invalid", application: null });
    });
    await enterCodeStep();
    assert.dom(".d-otp-animated__slot").exists({ count: 6 });
    await fillIn(".d-otp-input", "001234");
    assert.strictEqual(requests, 1);
    assert.dom(".isbf-alumni-registration__code").doesNotExist();
    assert.dom(".isbf-alumni-registration textarea").exists();
  });

  test("rejected codes clear while the error remains", async function (assert) {
    pretender.post("/isbf/alumni/applications/verify-email", () =>
      response(422, { errors: ["Invalid or expired code"] })
    );
    await enterCodeStep();
    await fillIn(".d-otp-input", "123456");
    assert.dom(".d-otp-input").hasValue("").isFocused();
    assert
      .dom("#alumni-registration-error")
      .includesText("Invalid or expired code");
    await fillIn(".d-otp-input", "1");
    assert.dom("#alumni-registration-error").doesNotExist();
  });

  test("server failures retain the code for retry", async function (assert) {
    let requests = 0;
    pretender.post("/isbf/alumni/applications/verify-email", () => {
      requests++;
      return requests === 1
        ? response(503, { errors: ["Try again"] })
        : response({ email: "graduate@example.invalid", application: null });
    });
    await enterCodeStep();
    await fillIn(".d-otp-input", "123456");
    assert.dom(".d-otp-input").hasValue("123456").isNotDisabled();
    await click(".isbf-alumni-registration__code button[type='submit']");
    assert.strictEqual(requests, 2);
    assert.dom(".isbf-alumni-registration__code").doesNotExist();
  });

  test("resending replaces a partially filled input", async function (assert) {
    await enterCodeStep();
    await fillIn(".d-otp-input", "123");
    await click(".isbf-alumni-registration__code button[type='button']");
    assert.dom(".d-otp-input").hasValue("");
    assert.dom(".d-otp-animated__slot[data-filled]").doesNotExist();
  });
});
