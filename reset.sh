#!/bin/bash


virsh destroy esxi-host
virsh undefine --remove-all-storage --nvram  esxi-host
