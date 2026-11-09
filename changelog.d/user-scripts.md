### Added

- Profile `[scripts] run = [...]` lists your own executables to run after every
  theme change and at teardown, with the active palette in `MACARCHY_*`
  environment variables. Scripts run without a shell, for at most 10 seconds,
  and only when they and their directory are yours and not writable by others.
  Each script's result shows under the `user-scripts` consumer.
