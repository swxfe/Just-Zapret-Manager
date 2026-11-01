#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then printf 'ZIP fixture\n' > "$2"; exit 0; fi
    shift
done
exit 2
