import { DurableObject } from 'cloudflare:workers';
import { createWorker, WakeRegistrationStore, WakeAdmissionStore } from './worker.mjs';

export class WakeAdmission extends DurableObject {
  constructor(state, env) {
    super(state, env);
    this.admission = new WakeAdmissionStore(state, env);
  }
  admit(source, handle, create) { return this.admission.admit(source, handle, create); }
  reserve(handle) { return this.admission.reserve(handle); }
  activate(handle, registrationExpiresAt) {
    return this.admission.activate(handle, registrationExpiresAt);
  }
  release(handle) { return this.admission.release(handle); }
  retireLegacy(handle) { return this.admission.retireLegacy(handle); }
}

export class WakeRegistration extends DurableObject {
  constructor(state, env) {
    super(state, env);
    this.registration = new WakeRegistrationStore(state, env);
  }

  fetch(request) {
    return this.registration.fetch(request);
  }

  bootstrap(handle, record) {
    return this.registration.bootstrap(handle, record);
  }

  reconcileExpiry(handle) {
    return this.registration.reconcileExpiry(handle);
  }

  wake(handle) {
    return this.registration.wake(handle);
  }

  alarm() {
    return this.registration.alarm();
  }
}

export default createWorker();
