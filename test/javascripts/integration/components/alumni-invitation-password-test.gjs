import {
  clearRender,
  click,
  fillIn,
  find,
  render,
  settled,
  waitUntil,
} from "@ember/test-helpers";
import { module, test } from "qunit";
import sinon from "sinon";
import PluginOutlet from "discourse/components/plugin-outlet";
import lazyHash from "discourse/helpers/lazy-hash";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import { i18n } from "discourse-i18n";
import IsbfAlumniInviteForm from "discourse/plugins/isbf-alumni/discourse/components/isbf-alumni-invite-form";
import IsbfAlumniInviteConnector from "discourse/plugins/isbf-alumni/discourse/connectors/academy-invitation-form/isbf-alumni-invite-form";
import { preventAlumniAutoCreation } from "discourse/plugins/isbf-alumni/discourse/lib/alumni-invite-password";

const PASSWORD = "Alumni-test-passphrase-123!";

function approvedInvite() {
  return {
    isbf_alumni_invite: true,
    email: "a***@example.invalid",
    token: "fresh-approved-alumni-fixture",
  };
}

async function renderInvite(context) {
  await render(
    <template>
      <IsbfAlumniInviteForm
        @invitation={{context.invitation}}
        @onAuthenticated={{context.onAuthenticated}}
        @usernameHint="alumni_test"
      />
    </template>
  );
}

async function verifyEmail() {
  await click(".code-login-form__continue");
  await fillIn(".d-otp-input", "123456");
}

module("Alumni invitation password | real CodeLoginForm", function (hooks) {
  setupRenderingTest(hooks);

  hooks.beforeEach(function () {
    this.invitation = approvedInvite();
    this.onAuthenticated = sinon.spy();
    this.siteSettings.min_password_length = 10;
    this.siteSettings.enable_random_usernames = false;
    this.created = 0;
    this.passwordWrites = [];
    this.invitationWrites = [];
    this.sequence = [];
    this.generatedUsername = false;
    this.passwordStatus = 200;
    this.passwordErrorType = "unknown";
    this.codeError = false;

    pretender.get("/session/hp.json", () =>
      response({ value: "hp-test", challenge: "test", expires_in: 300 })
    );
    pretender.post("/session/login-code", () => response({ success: "OK" }));
    pretender.get("/u/check_username", () =>
      response({ available: true, avatar_template: "/letter/a.png" })
    );
    pretender.get("/session/csrf", () => {
      this.sequence.push("csrf");
      return response({ csrf: "fresh-test-csrf" });
    });
    pretender.post("/session/login-code/verify", (request) => {
      const data = new URLSearchParams(request.requestBody);
      if (this.codeError) {
        return response({ error: "Invalid fixture code" });
      }
      if (!data.get("username")) {
        return response({
          username_required: true,
          username: "alumni_test",
          generated_username: this.generatedUsername,
        });
      }
      this.created++;
      this.sequence.push("created");
      return response({ account_created: true, redirect_url: "/latest" });
    });
    pretender.put("/isbf/alumni/initial-password", (request) => {
      this.sequence.push("password");
      this.passwordWrites.push(
        new URLSearchParams(request.requestBody).get("password")
      );
      this.invitationWrites.push(
        new URLSearchParams(request.requestBody).get("invite_key")
      );
      return response(
        this.passwordStatus,
        this.passwordStatus === 200
          ? { success: "OK" }
          : {
              errors: ["Fixture password save error"],
              error_type: this.passwordErrorType,
            }
      );
    });
  });

  test("only explicit approved new Alumni invitations replace the native fallback", function (assert) {
    assert.true(
      IsbfAlumniInviteConnector.shouldRender({ invitation: approvedInvite() })
    );
    assert.false(IsbfAlumniInviteConnector.shouldRender({ invitation: {} }));
    assert.false(
      IsbfAlumniInviteConnector.shouldRender({
        invitation: { isbf_alumni_invite: "true" },
      })
    );
    assert.false(
      IsbfAlumniInviteConnector.shouldRender({
        invitation: { ...approvedInvite(), existing_user_id: 42 },
      })
    );
  });

  test("native wrapper outlet uses the Alumni connector only for a marked invitation", async function (assert) {
    await render(
      <template>
        <PluginOutlet
          @name="academy-invitation-form"
          @outletArgs={{lazyHash
            invitation=this.invitation
            onAuthenticated=this.onAuthenticated
            usernameHint="alumni_test"
          }}
        ><span class="native-invitation-fallback">Native</span></PluginOutlet>
      </template>
    );
    assert.dom(".isbf-alumni-invite-form").exists();
    assert.dom(".native-invitation-fallback").doesNotExist();
    this.set("invitation", { ...this.invitation, isbf_alumni_invite: false });
    await settled();
    assert.dom(".isbf-alumni-invite-form").doesNotExist();
    assert.dom(".native-invitation-fallback").hasText("Native");
  });

  test("password is checked by default and precedes native email verification; unchecking clears it", async function (assert) {
    await renderInvite(this);
    assert.dom(".isbf-alumni-invite-form__enable-password").isChecked();
    assert
      .dom("#isbf-alumni-initial-password")
      .hasAttribute("autocomplete", "new-password");
    assert.strictEqual(
      find(".isbf-alumni-invite-form__password").compareDocumentPosition(
        find(".code-login-form")
      ),
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    await fillIn("#isbf-alumni-initial-password", PASSWORD);
    await click(".isbf-alumni-invite-form__enable-password");
    assert.dom("#isbf-alumni-initial-password").doesNotExist();
    assert
      .dom(".isbf-alumni-invite-form__code-help")
      .hasText(i18n("isbf_alumni.invite.code_login_help"));
    await click(".isbf-alumni-invite-form__enable-password");
    assert.dom("#isbf-alumni-initial-password").hasNoValue();
    assert.strictEqual(this.created, 0);
  });

  test("a code error remains native and never advances the password gate", async function (assert) {
    this.codeError = true;
    await renderInvite(this);
    await fillIn("#isbf-alumni-initial-password", PASSWORD);
    await verifyEmail();
    assert.dom(".code-login-form__error").hasText("Invalid fixture code");
    assert.dom("#isbf-alumni-initial-password").hasValue(PASSWORD);
    assert.dom(".isbf-alumni-invite-form__verified").doesNotExist();
    assert.strictEqual(this.created, 0);
  });

  test("bad password gates verified details and back preserves the same native fields", async function (assert) {
    await renderInvite(this);
    const native = find(".code-login-form");
    await fillIn("#isbf-alumni-initial-password", "short");
    await verifyEmail();
    assert.dom(".isbf-alumni-invite-form__native").hasAttribute("hidden");
    assert.dom(".isbf-alumni-invite-form__verified").exists();
    assert.dom("#isbf-alumni-password-validation").exists();
    assert.strictEqual(this.created, 0);
    await click(".isbf-alumni-invite-form__details");
    assert.dom(".isbf-alumni-invite-form__native").hasAttribute("hidden");
    await fillIn("#isbf-alumni-initial-password", PASSWORD);
    await click(".isbf-alumni-invite-form__details");
    assert
      .dom(".isbf-alumni-invite-form__native")
      .doesNotHaveAttribute("hidden");
    await fillIn("#code-login-username", "edited_alumni");
    await click(".isbf-alumni-invite-form__edit");
    assert.dom("#isbf-alumni-initial-password").hasValue(PASSWORD);
    await click(".isbf-alumni-invite-form__details");
    assert.strictEqual(find(".code-login-form"), native);
    assert.dom("#code-login-username").hasValue("edited_alumni");
    assert.strictEqual(this.created, 0);
  });

  test("site password rules remain reactive", async function (assert) {
    await renderInvite(this);
    await fillIn("#isbf-alumni-initial-password", PASSWORD);
    this.siteSettings.min_password_length = PASSWORD.length + 1;
    await verifyEmail();
    assert.dom(".isbf-alumni-invite-form__native").hasAttribute("hidden");
    this.siteSettings.min_password_length = 10;
    await settled();
    await click(".isbf-alumni-invite-form__details");
    assert
      .dom(".isbf-alumni-invite-form__native")
      .doesNotHaveAttribute("hidden");
  });

  test("generated username waits for final details action and scoped guard cleans up", async function (assert) {
    this.generatedUsername = true;
    await renderInvite(this);
    await fillIn("#isbf-alumni-initial-password", PASSWORD);
    await verifyEmail();
    assert.strictEqual(
      this.created,
      0,
      "generated username does not create an account automatically"
    );
    assert.false(
      preventAlumniAutoCreation({
        value: true,
        context: { context: "invite" },
      })
    );
    assert.true(
      preventAlumniAutoCreation({
        value: true,
        context: { context: "signup" },
      })
    );
    await clearRender();
    assert.true(
      preventAlumniAutoCreation({
        value: true,
        context: { context: "invite" },
      })
    );
  });

  test("success refreshes CSRF after creation then saves once and continues with native payload", async function (assert) {
    await renderInvite(this);
    await fillIn("#isbf-alumni-initial-password", PASSWORD);
    await verifyEmail();
    assert.dom("#isbf-alumni-initial-password").doesNotExist();
    assert.strictEqual(this.created, 0);
    await click(".code-login-form__continue-to-site");
    assert.deepEqual(this.sequence.slice(-3), ["created", "csrf", "password"]);
    assert.deepEqual(this.passwordWrites, [PASSWORD]);
    assert.deepEqual(this.invitationWrites, [this.invitation.token]);
    assert.true(
      this.onAuthenticated.calledOnceWithExactly({
        accountCreated: true,
        redirectUrl: "/latest",
      })
    );
  });

  test("unselected password creates the account without any password write", async function (assert) {
    await renderInvite(this);
    await click(".isbf-alumni-invite-form__enable-password");
    await verifyEmail();
    await click(".code-login-form__continue-to-site");
    assert.deepEqual(this.passwordWrites, []);
    assert.true(this.onAuthenticated.calledOnce);
  });

  test("an unconfirmed response retries the same password without reconsuming the invitation", async function (assert) {
    this.passwordStatus = 503;
    await renderInvite(this);
    await fillIn("#isbf-alumni-initial-password", PASSWORD);
    await verifyEmail();
    await click(".code-login-form__continue-to-site");
    assert
      .dom(".isbf-alumni-invite-form__result [role='alert']")
      .hasText(i18n("isbf_alumni.invite.password_unconfirmed"));
    assert.false(this.onAuthenticated.called);
    this.passwordStatus = 200;
    await click(".isbf-alumni-invite-form__retry");
    assert.deepEqual(this.passwordWrites, [PASSWORD, PASSWORD]);
    assert.strictEqual(this.created, 1);
    assert.true(this.onAuthenticated.calledOnce);
  });

  test("failure can be skipped and a different existing password is never overwritten", async function (assert) {
    this.passwordStatus = 409;
    await renderInvite(this);
    await fillIn("#isbf-alumni-initial-password", PASSWORD);
    await verifyEmail();
    await click(".code-login-form__continue-to-site");
    assert.dom(".isbf-alumni-invite-form__retry").doesNotExist();
    await click(".isbf-alumni-invite-form__skip");
    assert.strictEqual(this.passwordWrites.length, 1);
    assert.strictEqual(this.created, 1);
    assert.true(this.onAuthenticated.calledOnce);
  });

  test("session expiry clears secret and offers existing login", async function (assert) {
    this.passwordStatus = 403;
    this.passwordErrorType = "not_logged_in";
    const destruction = sinon.spy(
      IsbfAlumniInviteForm.prototype,
      "willDestroy"
    );
    try {
      await renderInvite(this);
      await fillIn("#isbf-alumni-initial-password", PASSWORD);
      await verifyEmail();
      await click(".code-login-form__continue-to-site");
      assert
        .dom(".isbf-alumni-invite-form__result a")
        .hasAttribute("href", "/login");
      assert.dom(".isbf-alumni-invite-form__retry").doesNotExist();
      await clearRender();
      assert.strictEqual(destruction.thisValues[0].accountPassword, "");
      assert.false(this.onAuthenticated.called);
    } finally {
      destruction.restore();
    }
  });

  test("destroy during password write ignores late success and clears component memory", async function (assert) {
    let resolveWrite;
    let writing = false;
    const destruction = sinon.spy(
      IsbfAlumniInviteForm.prototype,
      "willDestroy"
    );
    pretender.put("/isbf/alumni/initial-password", async () => {
      writing = true;
      await new Promise((resolve) => (resolveWrite = resolve));
      return response({ success: "OK" });
    });
    try {
      await renderInvite(this);
      await fillIn("#isbf-alumni-initial-password", PASSWORD);
      await verifyEmail();
      const submission = click(".code-login-form__continue-to-site");
      await waitUntil(() => writing);
      const teardown = clearRender();
      resolveWrite();
      await Promise.all([submission, teardown]);
      assert.strictEqual(destruction.thisValues[0].accountPassword, "");
      assert.false(this.onAuthenticated.called);
    } finally {
      destruction.restore();
    }
  });

  test("page leave clears password memory", async function (assert) {
    await renderInvite(this);
    await fillIn("#isbf-alumni-initial-password", PASSWORD);
    window.dispatchEvent(new Event("pagehide"));
    await settled();
    assert.dom("#isbf-alumni-initial-password").hasNoValue();
  });
});
