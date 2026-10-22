const mountedForms = new Set();

export function mountAlumniInvite(key) {
  mountedForms.add(key);
}

export function unmountAlumniInvite(key) {
  mountedForms.delete(key);
}

export function preventAlumniAutoCreation({ value, context }) {
  return context.context === "invite" && mountedForms.size > 0 ? false : value;
}
