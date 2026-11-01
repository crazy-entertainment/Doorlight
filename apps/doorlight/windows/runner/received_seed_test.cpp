#include "verified_received_seed.h"
#include "received_file_receipt.h"
#include <cassert>
#include <chrono>
#include <fstream>

struct TestDigest {
  std::string value;
  void update(const unsigned char* bytes, unsigned count) {
    value.append(reinterpret_cast<const char*>(bytes), count);
  }
  std::string finish() { return value.empty() ? "empty" : value; }
};

struct ReceiptDigest : TestDigest {
  std::string finish() { return std::string(128, value == "verified" ? 'a' : 'b'); }
};

static void Write(const std::filesystem::path& path, const std::string& bytes) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output << bytes;
  assert(output.good());
}
static std::string Read(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

int main() {
  namespace fs = std::filesystem;
  using jami::received_seed::publish;
  const auto root = fs::current_path() / ("received-seed-test-" +
      std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  assert(fs::create_directory(root));
  const auto source = root / "source";
  const auto seed = root / "seed";
  const auto temporary = root / "temporary";
  Write(source, "verified");
  assert(publish<TestDigest>(source, seed, temporary, 8, "verified"));
  assert(Read(source) == "verified" && Read(seed) == "verified");
  assert(!fs::exists(temporary));
  Write(source, "changed!");
  assert(Read(seed) == "verified"); // independent copy, not a source hard link
  assert(publish<TestDigest>(source, seed, temporary, 8, "verified"));
  assert(!publish<TestDigest>(source, seed, temporary, 8, "changed!"));
  assert(Read(seed) == "verified"); // never replace an existing seed
  fs::remove(seed);
  assert(!publish<TestDigest>(source, seed, temporary, 7, "changed!"));
  assert(!publish<TestDigest>(source, seed, temporary, 8, "wrong"));
  assert(!fs::exists(seed) && !fs::exists(temporary));
  Write(temporary, "not-ours");
  assert(!publish<TestDigest>(source, seed, temporary, 8, "changed!"));
  assert(Read(temporary) == "not-ours");
  fs::remove(temporary);
  Write(source, "");
  assert(publish<TestDigest>(source, seed, temporary, 0, "empty"));
  assert(fs::file_size(seed) == 0);
  fs::remove(seed);
  assert(!publish<TestDigest>(root, seed, temporary, 0, "empty"));
  const auto link = root / "link";
  std::error_code ec;
  fs::create_symlink(source, link, ec);
  if (!ec) {
    assert(!publish<TestDigest>(link, seed, temporary, 0, "empty"));
    fs::remove(link);
  }
  // A download targeting the seed directly must still verify its content.
  assert(publish<TestDigest>(source, source, temporary, 0, "empty"));
  assert(!publish<TestDigest>(source, source, temporary, 1, "empty"));
  // A preexisting directory is never replaced during publication.
  assert(fs::create_directory(seed));
  assert(!publish<TestDigest>(source, seed, temporary, 0, "empty"));
  assert(fs::is_directory(seed) && !fs::exists(temporary));
  fs::remove(seed);
  using namespace jami::received_seed;
  // Receive finalization hashes and publishes the same opened object.
  const auto partial = root / "receive.tmp";
  const auto final = root / "receive";
  {
    File receive(partial, File::Mode::append);
    assert(receive.valid());
    assert(receive.write(reinterpret_cast<const unsigned char*>("verified"), 8));
    assert(receive.size() == 8 && receive.flush());
    assert(readVerified<TestDigest>(receive, 8, "verified"));
    assert(receive.publishTo(final));
    assert(!receive.removeOwned()); // publication is never undone by cleanup
    receive.close();
    assert(Read(final) == "verified" && !fs::exists(partial));
  }
  {
    File receive(partial, true);
    assert(receive.valid());
    assert(!receive.publishTo(final)); // preserve the existing destination
    assert(receive.removeOwned());
  }
  assert(Read(final) == "verified");
  fs::remove(final);
  Write(partial, "verified");
  const auto hard = root / "hard-link";
  fs::create_hard_link(partial, hard);
  { File receive(partial, File::Mode::append); assert(!receive.valid()); }
  assert(Read(hard) == "verified");
  fs::remove(hard);
  fs::remove(partial);

  const auto parent = root / "owned-parent";
  const auto moved = root / "moved-parent";
  const auto alias = root / "parent-alias";
  fs::create_directory(parent);
  Write(parent / "source", "verified");
  fs::create_directory_symlink(parent, alias, ec);
  if (!ec) {
    File redirected(alias / "source", false);
    File redirectedOutput(alias / "output", true);
    assert(!redirected.valid() && !redirectedOutput.valid());
    assert(!fs::exists(parent / "output"));
  }
  {
    File receive(parent / "temporary", true);
    assert(receive.valid());
    fs::rename(parent, moved, ec);
#ifdef _WIN32
    assert(ec); // all ancestors are held against rename and reparse changes
    assert(receive.removeOwned());
#else
    assert(!ec);
    fs::create_directory(parent);
    Write(parent / "temporary", "replacement");
    assert(!receive.publishTo(parent / "final"));
    assert(receive.removeOwned()); // only the original pinned directory
    assert(Read(parent / "temporary") == "replacement");
    fs::remove(parent / "temporary");
    fs::remove(parent);
#endif
  }
#ifndef _WIN32
  fs::rename(moved, parent);
  {
    File receive(parent / "temporary", true);
    assert(receive.valid());
    fs::rename(parent / "temporary", parent / "old");
    Write(parent / "temporary", "replacement");
    assert(!receive.removeOwned());
    assert(!receive.publishTo(parent / "final"));
    assert(Read(parent / "temporary") == "replacement");
  }
  fs::remove(parent / "old");
  fs::remove(parent / "temporary");
#endif
  fs::remove(alias, ec);
  fs::remove(parent / "source");
  assert(fs::remove(parent));
  Receipt receipt;
  receipt.account = "abcdef";
  receipt.conversation = std::string(40, 'c');
  receipt.commit = std::string(40, 'd');
  receipt.file = receipt.commit + "_1.dat";
  receipt.attempt = std::string(32, 'e');
  receipt.hash = std::string(128, 'a');
  receipt.size = 8;
  const auto completed = root / receipt.file;
  Write(completed, "verified");
  { File file(completed, false); receipt.identity = file.identity(); }
  assert(valid(receipt));
  assert(verifyReceipt<ReceiptDigest>(root, receipt, receipt.account, receipt.conversation, receipt.file));
  assert(!verifyReceipt<ReceiptDigest>(root, receipt, "bad", receipt.conversation, receipt.file));
  const auto receiptPath = root / "receipt";
  assert(saveReceipt(receiptPath, temporary, receipt));
  Receipt loaded;
  assert(loadReceipt(receiptPath, loaded));
  assert(loaded.identity == receipt.identity && loaded.attempt == receipt.attempt);
  assert(verifyReceipt<ReceiptDigest>(root, loaded, receipt.account, receipt.conversation, receipt.file));
  const auto encoded = encode(receipt);
  assert(!decode(encoded + "extra", loaded));
  assert(!decode(encoded.substr(0, encoded.size() - 1), loaded));
  Receipt invalid = receipt;
  invalid.file = "../outside";
  assert(encode(invalid).empty());
  invalid = receipt; invalid.size = 2ULL * 1024 * 1024 * 1024 + 1;
  assert(encode(invalid).empty());
  // Keep the old object alive under another name, so inode reuse cannot mask replacement.
  const auto prior = root / "prior";
  fs::rename(completed, prior);
  Write(completed, "verified");
  assert(!verifyReceipt<ReceiptDigest>(root, receipt, receipt.account, receipt.conversation, receipt.file));
  fs::remove(completed);
  fs::rename(prior, completed);
  Write(completed, "changed!");
  assert(!verifyReceipt<ReceiptDigest>(root, receipt, receipt.account, receipt.conversation, receipt.file));
  Write(temporary, "not-ours");
  assert(!saveReceipt(receiptPath, temporary, receipt));
  assert(Read(temporary) == "not-ours");
  fs::remove(temporary);
  fs::remove(receiptPath);
  fs::remove(completed);
  fs::remove(source);
  assert(fs::remove(root));
}
