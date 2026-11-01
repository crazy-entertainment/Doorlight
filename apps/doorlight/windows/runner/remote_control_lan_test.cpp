#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_lan.h"

#include <cassert>
#include <vector>

using sybl::remote::IsProvenSameLan;
using sybl::remote::LocalAdapterPrefix;
using sybl::remote::LocalIceObservation;
using sybl::remote::LocalIcePath;

int main() {
  const std::vector<LocalAdapterPrefix> ipv4{
      {"192.168.10.7", 24}, {"10.40.0.5", 16}};
  assert(IsProvenSameLan(
      {LocalIcePath::kHostToHost, "192.168.10.7", "192.168.10.99"},
      ipv4));
  assert(!IsProvenSameLan(
      {LocalIcePath::kHostToHost, "192.168.10.7", "192.168.11.2"},
      ipv4));
  assert(!IsProvenSameLan(
      {LocalIcePath::kHostToHost, "192.168.10.7", "8.8.8.8"},
      ipv4));
  assert(!IsProvenSameLan(
      {LocalIcePath::kHostToHost, "192.168.20.7", "192.168.20.8"},
      ipv4));
  assert(!IsProvenSameLan(
      {LocalIcePath::kRelay, "192.168.10.7", "192.168.10.99"},
      ipv4));

  const std::vector<LocalAdapterPrefix> ipv6{
      {"fe80::1234", 64, 7}, {"fd42:1234:5678::10", 64},
      {"2001:db8:1::10", 64}};
  assert(IsProvenSameLan(
      {LocalIcePath::kHostToHost, "fe80::1234%7", "fe80::abcd%7"},
      ipv6));
  assert(!IsProvenSameLan(
      {LocalIcePath::kHostToHost, "fe80::1234%8", "fe80::abcd%8"},
      ipv6));
  assert(!IsProvenSameLan(
      {LocalIcePath::kHostToHost, "fe80::1234", "fe80::abcd"},
      ipv6));
  assert(IsProvenSameLan(
      {LocalIcePath::kHostToHost, "fd42:1234:5678::10",
       "fd42:1234:5678::20"},
      ipv6));
  assert(!IsProvenSameLan(
      {LocalIcePath::kHostToHost, "fd42:1234:5678::10",
       "fd42:1234:9999::20"},
      ipv6));
  assert(!IsProvenSameLan(
      {LocalIcePath::kHostToHost, "2001:db8:1::10",
       "2001:db8:1::20"},
      ipv6));
  assert(!IsProvenSameLan(
      {LocalIcePath::kHostToHost, "not-an-address", "192.168.10.99"},
      ipv4));
  return 0;
}
