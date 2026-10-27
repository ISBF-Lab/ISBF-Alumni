import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn, hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { schedule } from "@ember/runloop";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import waitForOtpFeedback from "discourse/lib/otp-feedback";
import { eq, not } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DOtp from "discourse/ui-kit/d-otp";
import DSelect from "discourse/ui-kit/d-select";
import { i18n } from "discourse-i18n";

const BASE = "/isbf/alumni";
const EMPTY = {
  real_name: "",
  graduation_year: "",
  country_code: "",
  region_code: "",
  city_code: "",
  city_name: "",
  industry: "",
  bio: "",
  visible: false,
};

export default class IsbfAlumniRegistration extends Component {
  @tracked application;
  @tracked busy = false;
  @tracked code = "";
  @tracked codeStatus = "idle";
  @tracked otpGeneration = 0;
  @tracked config;
  @tracked email = "";
  @tracked error;
  @tracked form = { ...EMPTY };
  @tracked notice;
  @tracked proofs = [];
  @tracked step = "loading";

  #requests = new Set();

  constructor() {
    super(...arguments);
    schedule("afterRender", this, this.load);
  }

  willDestroy() {
    super.willDestroy(...arguments);
    for (const request of this.#requests) {
      request.abort?.();
    }
    this.#requests.clear();
    this.email = "";
    this.code = "";
    this.form = { ...EMPTY };
    this.proofs = [];
    this.application = null;
  }

  get otpGenerationArray() {
    return [this.otpGeneration];
  }

  get verificationBusy() {
    return this.busy || this.codeStatus !== "idle";
  }

  get verifyDisabled() {
    return this.verificationBusy || !/^\d{6}$/.test(this.code);
  }

  get regions() {
    return (
      this.config?.countries?.find(
        (country) => country.code === this.form.country_code
      )?.regions || []
    );
  }

  get cities() {
    return (
      this.regions.find((region) => region.code === this.form.region_code)
        ?.cities || []
    );
  }

  get chineseCity() {
    return ["CN", "HK", "MO"].includes(this.form.country_code);
  }

  get editable() {
    return (
      this.step === "application" &&
      (!this.application ||
        ["draft", "rejected"].includes(this.application.status))
    );
  }

  get statusLabel() {
    return i18n(
      `isbf_alumni.registration.status_${this.application?.status || "pending"}`
    );
  }

  get years() {
    const current = new Date().getFullYear();
    return Array.from({ length: current - 1900 + 1 }, (_, index) =>
      String(current - index)
    );
  }

  @action
  async load() {
    await this.#run(async () => {
      this.config = await this.#request("/registration-config");
      if (!this.config.enabled) {
        this.step = "disabled";
        return;
      }
      const current = await this.#request("/applications/current");
      this.#restore(current);
    });
  }

  @action
  update(field, event) {
    const value =
      field === "visible" ? event.target.checked : event.target.value;
    this.form = { ...this.form, [field]: value };
    if (field === "country_code") {
      this.form = {
        ...this.form,
        region_code: "",
        city_code: "",
        city_name: "",
      };
    } else if (field === "region_code") {
      this.form = { ...this.form, city_code: "", city_name: "" };
    } else if (field === "city_code") {
      this.form = {
        ...this.form,
        city_name: this.cities.find((city) => city.code === value)?.name || "",
      };
    }
  }

  @action
  updateEmail(event) {
    this.email = event.target.value;
  }

  @action
  updateCode(setValue, code) {
    const rejecting = this.codeStatus === "error";
    this.code = code;
    this.codeStatus = "idle";
    setValue(code);
    if (!rejecting) {
      this.error = null;
    }
  }

  @action
  async sendCode(event) {
    event?.preventDefault();
    await this.#run(async () => {
      await this.#request("/applications/email", {
        type: "POST",
        data: { email: this.email.trim() },
      });
      this.code = "";
      this.codeStatus = "idle";
      this.otpGeneration++;
      this.step = "code";
      this.notice = i18n("isbf_alumni.registration.code_sent");
    });
  }

  @action
  async verify(event) {
    event?.preventDefault?.();
    if (this.verifyDisabled) {
      return;
    }
    await this.#run(async () => {
      try {
        const current = await this.#request("/applications/verify-email", {
          type: "POST",
          data: { code: this.code.trim() },
        });
        this.codeStatus = "success";
        await waitForOtpFeedback(this);
        if (this.isDestroying) {
          return;
        }
        this.#restore({ ...current, verified: true });
        this.code = "";
        this.codeStatus = "idle";
      } catch (error) {
        if (
          !this.isDestroying &&
          (error.jqXHR?.status ?? error.status) === 422
        ) {
          this.codeStatus = "error";
        }
        throw error;
      }
    });
  }

  @action
  async upload(event) {
    const files = Array.from(event.target.files || []);
    event.target.value = "";
    if (!files.length || this.busy) {
      return;
    }
    if (
      this.proofs.length + files.length > 5 ||
      files.some(
        (file) =>
          file.size > 10000000 ||
          !/\.(jpe?g|png|webp|heic|heif)$/i.test(file.name)
      )
    ) {
      this.error = i18n("isbf_alumni.registration.proof_invalid");
      return;
    }
    await this.#run(async () => {
      for (const file of files) {
        const data = new FormData();
        data.append("file", file);
        const proof = await this.#request("/application-proofs", {
          type: "POST",
          data,
          processData: false,
          contentType: false,
        });
        this.proofs = [...this.proofs, proof];
      }
    });
  }

  @action
  async remove(proof) {
    await this.#run(async () => {
      if (!proof.bound) {
        await this.#request(
          `/application-proofs/${encodeURIComponent(proof.id)}`,
          { type: "DELETE" }
        );
      }
      this.proofs = this.proofs.filter((item) => item.id !== proof.id);
    });
  }

  @action
  async submit(event) {
    event?.preventDefault();
    if (!this.proofs.length) {
      this.error = i18n("isbf_alumni.registration.proof_required");
      return;
    }
    await this.#run(async () => {
      const response = await this.#request("/applications", {
        type: "POST",
        data: {
          ...this.form,
          real_name: this.form.real_name.trim(),
          proof_ids: this.proofs.map((proof) => proof.id),
        },
      });
      this.application = response.application;
      this.notice = i18n("isbf_alumni.registration.submitted");
    });
  }

  @action
  async resend() {
    await this.#run(async () => {
      await this.#request("/applications/resend", { type: "POST" });
      this.notice = i18n("isbf_alumni.registration.resent");
    });
  }

  #restore(current) {
    this.email = current.email || this.email;
    this.application = current.application;
    this.form = Object.fromEntries(
      Object.entries(EMPTY).map(([key, fallback]) => [
        key,
        current.application?.[key] ?? fallback,
      ])
    );
    this.form = {
      ...this.form,
      graduation_year: String(this.form.graduation_year || ""),
    };
    this.proofs = current.application?.proofs || [];
    this.step = current.verified ? "application" : "email";
  }

  async #request(path, options = {}) {
    if (this.isDestroying) {
      throw new Error("Cancelled");
    }
    const request = ajax(BASE + path, options);
    this.#requests.add(request);
    try {
      const result = await request;
      if (this.isDestroying) {
        throw new Error("Cancelled");
      }
      return result;
    } finally {
      this.#requests.delete(request);
    }
  }

  async #run(callback) {
    if (this.isDestroying || this.busy) {
      return;
    }
    this.busy = true;
    this.error = null;
    this.notice = null;
    try {
      await callback();
    } catch (error) {
      if (!this.isDestroying) {
        this.error = extractError(error);
      }
    } finally {
      if (!this.isDestroying) {
        this.busy = false;
      }
    }
  }

  <template>
    <section aria-busy={{this.busy}} class="isbf-alumni-registration">
      <h1>{{i18n "isbf_alumni.registration.title"}}</h1>
      {{#if this.error}}<p
          id="alumni-registration-error"
          role="alert"
        >{{this.error}}</p>{{/if}}
      {{#if this.notice}}<p role="status">{{this.notice}}</p>{{/if}}
      {{#if (eq this.step "loading")}}
        {{#if this.error}}<DButton
            @action={{this.load}}
            @label="isbf_alumni.registration.retry"
          />{{else}}<p>{{i18n "loading"}}</p>{{/if}}
      {{else if (eq this.step "disabled")}}
        <p>{{i18n "isbf_alumni.registration.disabled"}}</p>
      {{else if (eq this.step "email")}}
        <form {{on "submit" this.sendCode}}>
          <label>{{i18n "isbf_alumni.registration.email"}}<input
              autocomplete="email"
              disabled={{this.busy}}
              required
              type="email"
              value={{this.email}}
              {{on "input" this.updateEmail}}
            /></label>
          <p>{{i18n "isbf_alumni.registration.email_help"}}</p>
          <button
            class="btn btn-primary"
            disabled={{this.busy}}
            type="submit"
          >{{i18n "isbf_alumni.registration.send_code"}}</button>
        </form>
      {{else if (eq this.step "code")}}
        <Form
          class="isbf-alumni-registration__code"
          @data={{hash code=this.code}}
          @onSubmit={{this.verify}}
          as |form|
        >
          <p>{{this.email}}</p>
          <form.Field
            @name="code"
            @title={{i18n "isbf_alumni.registration.code"}}
            @type="custom"
            @validation="required"
            as |field|
          >
            <field.Control>
              {{#each this.otpGenerationArray as |generation|}}
                <DOtp
                  aria-label={{i18n "isbf_alumni.registration.code"}}
                  data-generation={{generation}}
                  id={{field.id}}
                  @describedBy="alumni-registration-error"
                  @disabled={{this.busy}}
                  @invalid={{this.error}}
                  @onChange={{fn this.updateCode field.set}}
                  @onFill={{this.verify}}
                  @status={{this.codeStatus}}
                  @value={{this.code}}
                  @variant="animated"
                />
              {{/each}}
            </field.Control>
          </form.Field>
          <form.Submit
            @disabled={{this.verifyDisabled}}
            @label="isbf_alumni.registration.verify"
          />
          <DButton
            @action={{this.sendCode}}
            @disabled={{this.verificationBusy}}
            @label="isbf_alumni.registration.send_again"
          />
        </Form>
      {{else if this.editable}}
        {{#if this.application.rejection_reason}}<p
            class="isbf-alumni-registration__rejection"
          >{{this.application.rejection_reason}}</p>{{/if}}
        <form {{on "submit" this.submit}}>
          <fieldset disabled={{this.busy}}>
            <label>{{i18n "isbf_alumni.registration.real_name"}}<input
                autocomplete="name"
                maxlength="80"
                required
                value={{this.form.real_name}}
                {{on "input" (fn this.update "real_name")}}
              /></label>
            <label>{{i18n "isbf_alumni.registration.graduation_year"}}<DSelect
                required
                @includeNone={{false}}
                @onInput={{fn this.update "graduation_year"}}
              ><option value="">—</option>{{#each this.years as |year|}}<option
                    selected={{eq this.form.graduation_year year}}
                    value={{year}}
                  >{{year}}</option>{{/each}}</DSelect></label>
            <p>{{this.email}}</p>
            <label>{{i18n "isbf_alumni.registration.country"}}<DSelect
                @includeNone={{false}}
                @onInput={{fn this.update "country_code"}}
              ><option value="">—</option>{{#each
                  this.config.countries
                  as |country|
                }}<option
                    selected={{eq country.code this.form.country_code}}
                    value={{country.code}}
                  >{{country.name}}</option>{{/each}}</DSelect></label>
            {{#if this.regions.length}}<label>{{i18n
                  "isbf_alumni.registration.region"
                }}<DSelect
                  @includeNone={{false}}
                  @onInput={{fn this.update "region_code"}}
                ><option value="">—</option>{{#each
                    this.regions
                    as |region|
                  }}<option
                      selected={{eq region.code this.form.region_code}}
                      value={{region.code}}
                    >{{region.name}}</option>{{/each}}</DSelect></label>{{/if}}
            <label>{{i18n "isbf_alumni.registration.city"}}
              {{#if this.chineseCity}}<DSelect
                  disabled={{not this.cities.length}}
                  @includeNone={{false}}
                  @onInput={{fn this.update "city_code"}}
                ><option value="">—</option>{{#each
                    this.cities
                    as |city|
                  }}<option
                      selected={{eq city.code this.form.city_code}}
                      value={{city.code}}
                    >{{city.name}}</option>{{/each}}</DSelect>
              {{else}}<input
                  maxlength="80"
                  value={{this.form.city_name}}
                  {{on "input" (fn this.update "city_name")}}
                />{{/if}}
            </label>
            <label>{{i18n "isbf_alumni.registration.industry"}}<input
                maxlength="60"
                value={{this.form.industry}}
                {{on "input" (fn this.update "industry")}}
              /></label>
            <label>{{i18n "isbf_alumni.registration.bio"}}<textarea
                maxlength="500"
                rows="4"
                value={{this.form.bio}}
                {{on "input" (fn this.update "bio")}}
              ></textarea></label>
            <label>{{i18n "isbf_alumni.registration.proofs"}}<input
                accept=".jpg,.jpeg,.png,.webp,.heic,.heif"
                multiple
                type="file"
                {{on "change" this.upload}}
              /></label>
            <p>{{i18n "isbf_alumni.registration.proof_help"}}</p>
            <ul class="isbf-alumni-registration__proofs">{{#each
                this.proofs
                as |proof|
              }}<li><a
                    href={{proof.url}}
                    rel="noopener noreferrer"
                    target="_blank"
                  >{{i18n "isbf_alumni.registration.preview"}}
                    ·
                    {{proof.bytes}}
                    B</a><DButton
                    @action={{fn this.remove proof}}
                    @disabled={{this.busy}}
                    @label="isbf_alumni.registration.remove"
                  /></li>{{/each}}</ul>
            <label class="isbf-alumni-registration__visibility"><input
                checked={{this.form.visible}}
                type="checkbox"
                {{on "change" (fn this.update "visible")}}
              />{{i18n "isbf_alumni.registration.visible"}}</label>
            <p>{{i18n "isbf_alumni.registration.privacy"}}</p>
            <button
              class="btn btn-primary"
              disabled={{this.busy}}
              type="submit"
            >{{i18n "isbf_alumni.registration.submit"}}</button>
          </fieldset>
        </form>
      {{else}}
        <h2>{{this.statusLabel}}</h2>
        <p>{{i18n "isbf_alumni.registration.status_help"}}</p>
        {{#if (eq this.application.status "approved")}}<DButton
            @action={{this.resend}}
            @disabled={{this.busy}}
            @label="isbf_alumni.registration.resend_invite"
          />{{/if}}
        <DButton
          @action={{this.load}}
          @disabled={{this.busy}}
          @label="isbf_alumni.registration.refresh"
        />
      {{/if}}
    </section>
  </template>
}
