#include "command_journal_store.h"
#include <cassert>
#include <chrono>
#include <fstream>

int main() {
  namespace fs = std::filesystem;
  const auto root = fs::current_path() / ("command-journal-test-" +
      std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  assert(fs::create_directory(root));
  const auto path = root / "journal.dpapi";
  const auto initial = sybl::journal::Load(path);
  assert(initial.healthy && !initial.source);
  const std::string first = R"({"v":1,"operations":[]})";
  assert(sybl::journal::Save(path, first));
  assert(sybl::journal::Load(path).source == first);
  std::ifstream file(path, std::ios::binary);
  const std::string sealed {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
  file.close();
  assert(sealed.find(first) == std::string::npos);
  const std::string second = R"({"v":1,"operations":[{"sentinel":"private-command-marker"}]})";
  assert(sybl::journal::Save(path, second));
  assert(sybl::journal::Load(path).source == second);
  assert(!sybl::journal::Save(path, std::string(1024 * 1024 + 1, 'x')));
  assert(sybl::journal::Load(path).source == second);
  { std::ofstream corrupt(path, std::ios::binary | std::ios::trunc); corrupt << "broken"; }
  assert(!sybl::journal::Load(path).healthy);
  assert(!sybl::journal::Save(path, first));
  assert(fs::file_size(path) == 6);
  assert(fs::remove(path));
  assert(fs::remove(path.wstring() + L".lock"));
  assert(fs::remove(root));
}
