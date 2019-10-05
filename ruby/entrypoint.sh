#!/bin/bash

bundle install --path vendor/bundle
# bundle exec falcon -b tcp://0.0.0.0:8000 --hybrid --forks 2 --threads 4
bundle exec puma -b tcp://0.0.0.0:8000 -e production -w 8
