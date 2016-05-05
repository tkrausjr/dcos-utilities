#!/bin/sh
print "This script will deploy many marathon applications"
jsonbase='{"id": "base", "cpus": 0.1, "mem": 32, "cmd": "python -m http.server $PORT0", "instances": 1, "container": {"docker": {"image": "python:3"}}}'

for i in {10..20}; do echo $jsonbase | sed -e "s/base/${i}/" > tmp-marathon-app.json; curl -X POST http://thomaskra-elasticl-afa8esocei7x-1552383049.us-east-1.elb.amazonaws.com/marathon/v2/apps --header "Content-Type: application/json" --header "Authorization: token=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJleHAiOiIxNDYyODQ2NTY1IiwidWlkIjoiYm9vdHN0cmFwdXNlciJ9.lwRX9QgZU8HVYhCBIo4VlcHBrXDxUPX7tLSnKJWop5s" --data-binary @./tmp-marathon-app.json; done
