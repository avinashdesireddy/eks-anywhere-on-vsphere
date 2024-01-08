#!/bin/bash


virsh destroy $1
virsh undefine --remove-all-storage --nvram  $1
