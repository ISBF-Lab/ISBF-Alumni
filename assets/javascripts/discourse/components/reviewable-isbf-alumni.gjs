import Component from "@glimmer/component";
import { i18n } from "discourse-i18n";

export default class ReviewableIsbfAlumni extends Component {
  get application() {
    return this.args.reviewable.payload?.application;
  }

  get location() {
    const application = this.application || {};
    return [
      application.country_name || application.country_code,
      application.region_name || application.region_code,
      application.city_name,
    ]
      .filter((part, index, parts) => part && part !== parts[index - 1])
      .join(" · ");
  }

  <template>
    {{#if this.application}}
      <div class="reviewable-isbf-alumni">
        <h3>{{i18n "isbf_alumni.registration.review_title"}}</h3>
        <dl>
          <dt>{{i18n "isbf_alumni.registration.real_name"}}</dt><dd
          >{{this.application.real_name}}</dd>
          <dt>{{i18n "isbf_alumni.registration.email"}}</dt><dd
          >{{this.application.email}}</dd>
          <dt>{{i18n "isbf_alumni.registration.graduation_year"}}</dt><dd
          >{{this.application.graduation_year}}</dd>
          {{#if this.location}}<dt>{{i18n
                "isbf_alumni.registration.location"
              }}</dt><dd>{{this.location}}</dd>{{/if}}
          {{#if this.application.industry}}<dt>{{i18n
                "isbf_alumni.registration.industry"
              }}</dt><dd>{{this.application.industry}}</dd>{{/if}}
          {{#if this.application.bio}}<dt>{{i18n
                "isbf_alumni.registration.bio"
              }}</dt><dd>{{this.application.bio}}</dd>{{/if}}
          {{#if this.application.rejection_reason}}<dt>{{i18n
                "isbf_alumni.registration.rejection_reason"
              }}</dt><dd>{{this.application.rejection_reason}}</dd>{{/if}}
          {{#if this.application.mail_status}}<dt>{{i18n
                "isbf_alumni.registration.mail_status"
              }}</dt><dd>{{this.application.mail_status}}</dd>{{/if}}
        </dl>
        <p>{{i18n "isbf_alumni.registration.proof_private"}}</p>
        <ul>{{#each this.application.proofs as |proof|}}<li><a
                href={{proof.url}}
                rel="noopener noreferrer"
                target="_blank"
              >{{i18n "isbf_alumni.registration.preview"}}
                ·
                {{proof.bytes}}
                B</a></li>{{/each}}</ul>
      </div>
    {{/if}}
  </template>
}
