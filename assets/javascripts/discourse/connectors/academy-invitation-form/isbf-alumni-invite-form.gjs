import Component from "@glimmer/component";
import IsbfAlumniInviteForm from "../../components/isbf-alumni-invite-form";

export default class IsbfAlumniInviteConnector extends Component {
  static shouldRender(args) {
    const invitation = args.invitation;
    return (
      invitation?.isbf_alumni_invite === true && !invitation.existing_user_id
    );
  }

  <template>
    <IsbfAlumniInviteForm
      @invitation={{@outletArgs.invitation}}
      @onAuthenticated={{@outletArgs.onAuthenticated}}
      @usernameHint={{@outletArgs.usernameHint}}
    />
  </template>
}
