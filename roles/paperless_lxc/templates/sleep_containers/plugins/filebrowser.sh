check_busy() {
  # FileBrowser reads are cheap; treat as never busy
  return 1
}
