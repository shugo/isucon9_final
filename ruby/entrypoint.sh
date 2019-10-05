#!/bin/bash

bundle install --path vendor/bundle
bundle exec falcon -b tcp://0.0.0.0:8000 --hybrid --forks 2 --threads 4

