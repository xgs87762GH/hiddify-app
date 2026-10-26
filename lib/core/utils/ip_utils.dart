const String fallbackObscuredAddress = "*.*.*.*";

String obscureIp(String ip) {
  // split/first/last cannot throw here: the previous empty catch only hid a bug if they ever did.
  if (ip.contains(".")) {
    final splits = ip.split(".");
    return "${splits.first}.*.*.${splits.last}";
  } else if (ip.contains(":")) {
    final splits = ip.split(":");
    return [splits.first, ...splits.sublist(1).map((part) => "*" * part.length)].join(":");
  }
  return fallbackObscuredAddress;
}
