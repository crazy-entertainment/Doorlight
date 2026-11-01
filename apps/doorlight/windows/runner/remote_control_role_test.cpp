#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_role.h"

#include <cassert>

using namespace sybl::remote;

int main() {
  RemoteControlRoleRegistry roles;
  assert(roles.TryClaim("call-a", LocalControlRole::kController));
  assert(roles.TryClaim("call-a", LocalControlRole::kController));
  assert(!roles.TryClaim("call-a", LocalControlRole::kControllee));
  assert(roles.RoleFor("call-a") == LocalControlRole::kController);
  assert(!roles.Release("call-a", LocalControlRole::kControllee));
  assert(roles.RoleFor("call-a") == LocalControlRole::kController);
  assert(roles.Release("call-a", LocalControlRole::kController));

  assert(roles.TryClaim("call-a", LocalControlRole::kControllee));
  assert(!roles.TryClaim("call-a", LocalControlRole::kController));
  assert(roles.Release("call-a", LocalControlRole::kControllee));
  assert(roles.RoleFor("call-a") == LocalControlRole::kNone);

  assert(roles.TryClaim("call-a", LocalControlRole::kController));
  assert(roles.TryClaim("call-b", LocalControlRole::kControllee));
  assert(roles.RoleFor("call-a") == LocalControlRole::kController);
  assert(roles.RoleFor("call-b") == LocalControlRole::kControllee);
}
