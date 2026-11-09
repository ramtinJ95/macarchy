### Added

- Profile `[scripts] run = [...]` lists your own executables to run after every
  theme change and at teardown, with the active palette in `MACARCHY_*`
  environment variables. Scripts run without a shell, for at most 10 seconds,
  and only when their resolved paths have trusted ownership and no writable
  ancestors or write-granting ACLs. Cancellation and termination signals stop
  the script and its original process group before Macarchy exits.
  Each script's result shows under the `user-scripts` consumer.
