#!/bin/bash

journalctl --rotate
journalctl --vacuum-time=1s
