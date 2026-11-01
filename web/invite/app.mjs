import config from './config.mjs';
import { applicationLink, configuredOrigin, parseInvitation } from './invitation.mjs';

const status = document.getElementById('status');
const invitation = document.getElementById('invitation');
const heading = document.getElementById('heading');

function showInvitation() {
  invitation.hidden = true;
  document.getElementById('continue').removeAttribute('href');
  const origin = configuredOrigin(config.origin);
  if (!origin || location.origin !== origin) {
    heading.textContent = 'This invitation site is not configured';
    status.textContent = 'Ask the person who invited you for a working invitation.';
    return;
  }
  const invite = parseInvitation(location.href, origin);
  if (!invite) {
    heading.textContent = 'This invitation could not be opened';
    status.textContent = 'The link is incomplete or invalid. Ask your friend to share it again.';
    return;
  }
  heading.replaceChildren();
  if (invite.name) {
    const name = document.createElement('bdi');
    name.textContent = invite.name;
    heading.append(name, ' invited you to Doorlight');
  } else heading.textContent = 'Your invitation to Doorlight';
  status.textContent = '';
  document.getElementById('friend-id').textContent = invite.id;
  document.getElementById('continue').href = applicationLink(invite);
  for (const [id, value] of [['windows-download', config.windowsDownload], ['android-download', config.androidDownload]]) {
    const element = document.getElementById(id);
    element.hidden = !value;
    if (value) element.href = value;
  }
  document.getElementById('download-unavailable').hidden = Boolean(config.windowsDownload || config.androidDownload);
  invitation.hidden = false;
}

showInvitation();
window.addEventListener('hashchange', showInvitation);
