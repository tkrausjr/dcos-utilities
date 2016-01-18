#!/bin/bash


# Check to see that the /var partition has enough space
varFree=$(df -g /var | tail -1 | awk '{print $4}')
if [ $varFree -ge  5]
then
  varFreeStatus="PASS"
else
  varFreeStatus="FAIL"
fi

echo "/var has" $varFree "GB available" 
echo $varFreeStatus


