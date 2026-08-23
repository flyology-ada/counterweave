#!/bin/sh

# A real adapter decodes the case and calls the system under test. This example
# only demonstrates the process protocol.
sed -n '$p' >/dev/null
printf '%s\n' '{"accepted":true}'
