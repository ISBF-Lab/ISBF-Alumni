import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import CodeLoginForm from "discourse/components/code-login-form";
import { ajax, updateCsrfToken } from "discourse/lib/ajax";
import PasswordValidationHelper from "discourse/lib/password-validation-helper";
import DButton from "discourse/ui-kit/d-button";
import DInputTip from "discourse/ui-kit/d-input-tip";
import { i18n } from "discourse-i18n";
import {
  mountAlumniInvite,
  unmountAlumniInvite,
} from "../lib/alumni-invite-password";

export default class IsbfAlumniInviteForm extends Component {
  @service siteSettings;

  @tracked accountPassword = "";
  @tracked passwordRequired = true;
  @tracked editingPassword = false;
  @tracked forceValidationReason = false;
  @tracked step = "email";
  @tracked saving = false;
  @tracked saveFailed = false;
  @tracked passwordConflict = false;
  @tracked sessionExpired = false;
  @tracked authenticated = false;

  passwordValidationHelper = new PasswordValidationHelper(this);

  #authenticatedPayload;
  #formKey = Symbol();
  #finished = false;
  #clearOnPageHide = () => {
    this.accountPassword = "";
  };

  constructor() {
    super(...arguments);
    mountAlumniInvite(this.#formKey);
    window.addEventListener("pagehide", this.#clearOnPageHide);
  }

  willDestroy() {
    unmountAlumniInvite(this.#formKey);
    window.removeEventListener("pagehide", this.#clearOnPageHide);
    this.accountPassword = "";
    this.#authenticatedPayload = null;
    super.willDestroy(...arguments);
  }

  get accountEmail() {
    return this.args.invitation.email;
  }

  get accountUsername() {
    return this.args.usernameHint;
  }

  get passwordValidation() {
    return this.passwordValidationHelper.passwordValidation;
  }

  get emailVerified() {
    return ["user-fields", "signup-details"].includes(this.step);
  }

  get showPassword() {
    return (
      !this.authenticated &&
      (!this.emailVerified ||
        this.editingPassword ||
        this.passwordValidation.failed)
    );
  }

  get hideNativeForm() {
    return (
      this.authenticated ||
      (this.emailVerified &&
        (this.editingPassword || this.passwordValidation.failed))
    );
  }

  get showValidation() {
    return (
      this.passwordRequired &&
      (this.forceValidationReason || this.accountPassword.length > 0)
    );
  }

  @action
  passwordChanged(event) {
    this.accountPassword = event.target.value;
  }

  @action
  togglePassword(event) {
    this.passwordRequired = event.target.checked;
    this.forceValidationReason = false;
    if (!this.passwordRequired) {
      this.accountPassword = "";
    }
  }

  @action
  onStepChange(step) {
    this.step = step;
    if (this.emailVerified) {
      this.forceValidationReason = true;
      this.editingPassword = this.passwordValidation.failed === true;
    }
  }

  @action
  editPassword() {
    this.editingPassword = true;
  }

  @action
  continueToDetails() {
    this.forceValidationReason = true;
    if (!this.passwordValidation.failed) {
      this.editingPassword = false;
    }
  }

  @action
  async onAuthenticated(payload) {
    if (this.authenticated || this.#finished || this.isDestroying) {
      return;
    }
    this.authenticated = true;
    this.#authenticatedPayload = payload;
    if (this.passwordRequired && payload.accountCreated) {
      await this.savePassword();
    } else {
      await this.#finish();
    }
  }

  @action
  async savePassword() {
    if (
      this.saving ||
      this.#finished ||
      this.isDestroying ||
      this.sessionExpired ||
      this.passwordConflict ||
      !this.#authenticatedPayload
    ) {
      return;
    }
    this.saving = true;
    this.saveFailed = false;
    let saved = false;
    try {
      await updateCsrfToken();
      if (this.isDestroying) {
        return;
      }
      if (!this.accountPassword) {
        this.saveFailed = true;
        return;
      }
      await ajax("/isbf/alumni/initial-password", {
        type: "PUT",
        data: {
          password: this.accountPassword,
          invite_key: this.args.invitation.token,
        },
      });
      saved = true;
    } catch (error) {
      if (!this.isDestroying) {
        const status = error.jqXHR?.status ?? error.status;
        const errorType =
          error.jqXHR?.responseJSON?.error_type ??
          error.responseJSON?.error_type;
        this.sessionExpired =
          status === 401 || (status === 403 && errorType === "not_logged_in");
        this.passwordConflict = status === 409;
        this.saveFailed = true;
        if (this.sessionExpired) {
          this.accountPassword = "";
          this.#authenticatedPayload = null;
        }
      }
    } finally {
      if (!this.isDestroying) {
        this.saving = false;
      }
    }
    if (saved && !this.isDestroying) {
      await this.#finish();
    }
  }

  @action
  async skipPassword() {
    if (!this.saving && !this.sessionExpired) {
      await this.#finish();
    }
  }

  async #finish() {
    if (this.#finished || this.isDestroying) {
      return;
    }
    this.#finished = true;
    const payload = this.#authenticatedPayload;
    this.accountPassword = "";
    this.#authenticatedPayload = null;
    await this.args.onAuthenticated(payload);
  }

  <template>
    <div class="isbf-alumni-invite-form">
      {{#if this.showPassword}}
        <section class="isbf-alumni-invite-form__password">
          <h2>{{i18n "isbf_alumni.invite.password_title"}}</h2>
          <label class="isbf-alumni-invite-form__choice">
            <input
              checked={{this.passwordRequired}}
              class="isbf-alumni-invite-form__enable-password"
              type="checkbox"
              {{on "change" this.togglePassword}}
            />
            {{i18n "isbf_alumni.invite.choose_password"}}
          </label>
          {{#if this.passwordRequired}}
            <label for="isbf-alumni-initial-password">
              {{i18n "user.password.title"}}
            </label>
            <input
              aria-describedby="isbf-alumni-password-instructions isbf-alumni-password-validation"
              aria-invalid={{if
                this.showValidation
                this.passwordValidation.failed
              }}
              autocomplete="new-password"
              id="isbf-alumni-initial-password"
              minlength={{this.siteSettings.min_password_length}}
              type="password"
              value={{this.accountPassword}}
              {{on "input" this.passwordChanged}}
            />
            <p id="isbf-alumni-password-instructions">
              {{this.passwordValidationHelper.passwordInstructions}}
            </p>
            {{#if this.showValidation}}
              <DInputTip
                id="isbf-alumni-password-validation"
                @validation={{this.passwordValidation}}
              />
            {{/if}}
          {{else}}
            <p class="isbf-alumni-invite-form__code-help">
              {{i18n "isbf_alumni.invite.code_login_help"}}
            </p>
          {{/if}}
        </section>
      {{/if}}

      {{#unless this.authenticated}}
        {{#if this.emailVerified}}
          {{#if this.showPassword}}
            <section
              aria-live="polite"
              class="isbf-alumni-invite-form__verified"
            >
              <h2>{{i18n "isbf_alumni.invite.email_title"}}</h2>
              <p>{{i18n "isbf_alumni.invite.email_verified"}}</p>
              <DButton
                class="btn-primary isbf-alumni-invite-form__details"
                @action={{this.continueToDetails}}
                @label="isbf_alumni.invite.continue"
              />
            </section>
          {{else}}
            <DButton
              class="btn-flat isbf-alumni-invite-form__edit"
              @action={{this.editPassword}}
              @label="isbf_alumni.invite.edit_password"
            />
          {{/if}}
        {{else}}
          <h2>{{i18n "isbf_alumni.invite.email_title"}}</h2>
        {{/if}}
      {{/unless}}

      {{! Keep the native instance alive so verified email and detail fields survive back navigation. }}
      <div
        class="isbf-alumni-invite-form__native"
        hidden={{this.hideNativeForm}}
      >
        <CodeLoginForm
          @context="invite"
          @emailLocked={{true}}
          @initialEmail={{@invitation.email}}
          @inviteKey={{@invitation.token}}
          @onAuthenticated={{this.onAuthenticated}}
          @onStepChange={{this.onStepChange}}
          @usernameHint={{@usernameHint}}
        />
      </div>

      {{#if this.authenticated}}
        <div aria-live="polite" class="isbf-alumni-invite-form__result">
          {{#if this.sessionExpired}}
            <p role="alert">{{i18n "isbf_alumni.invite.session_expired"}}</p>
            <a href="/login">{{i18n "isbf_alumni.invite.login"}}</a>
          {{else if this.saveFailed}}
            <p role="alert">{{i18n
                "isbf_alumni.invite.password_unconfirmed"
              }}</p>
            {{#if this.passwordConflict}}
              <p>{{i18n "isbf_alumni.invite.password_conflict"}}</p>
            {{else}}
              <DButton
                class="btn-primary isbf-alumni-invite-form__retry"
                @action={{this.savePassword}}
                @label="isbf_alumni.registration.retry"
              />
            {{/if}}
            <DButton
              class="btn-flat isbf-alumni-invite-form__skip"
              @action={{this.skipPassword}}
              @label="isbf_alumni.invite.skip"
            />
          {{else if this.saving}}
            <p role="status">{{i18n "isbf_alumni.invite.saving"}}</p>
          {{/if}}
        </div>
      {{/if}}
    </div>
  </template>
}
