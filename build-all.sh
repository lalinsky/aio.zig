#!/usr/bin/env bash

set -euo pipefail

for backend in io_uring epoll poll; do
  zig build test -Dbackend=$backend -Dtarget=x86_64-linux
done

for os in macos freebsd netbsd; do
  for backend in kqueue poll; do
    zig build -Dinstall-tests -Dbackend=$backend -Dtarget=x86_64-$os
  done
done

zig build -Dinstall-tests -Dbackend=poll -Dtarget=x86_64-windows
