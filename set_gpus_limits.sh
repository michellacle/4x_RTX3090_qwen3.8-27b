#!/bin/bash

sudo nvidia-smi -i 0,1,2,3 -pm 1 && sudo nvidia-smi -i 0,1,2,3 -pl 225

