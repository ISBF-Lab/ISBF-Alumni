import { withPluginApi } from "discourse/lib/plugin-api";
import { preventAlumniAutoCreation } from "../lib/alumni-invite-password";

export default {
  name: "isbf-alumni-invite-password",

  initialize() {
    withPluginApi((api) => {
      api.registerValueTransformer(
        "code-login-auto-create-account",
        preventAlumniAutoCreation
      );
    });
  },
};
