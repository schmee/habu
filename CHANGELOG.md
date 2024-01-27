### 20240127

#### Bugfixes

- Fix memory alignment issue that sometimes happened with empty databases: https://github.com/schmee/habu/issues/5

### 20240109

#### Bugfixes

- Fix week number calculation when transitioning from one year to the next.
- Fix date parsing when using the `nth` syntax and selecting a date in a previous year.
- Fix bug that would sometimes cause weekly chains spanning a year transition to appear broken.
- Fix chain `info` stats for chains spanning multiple years.

### 20231126

- Add new date formats
    - Nth, Nst, Nrd, Nnd: Nth day of the current month is N >= today, else Nth day of previous month
    - Weekdays: mon/monday, tue/tuesday...
    - N: N days ago (1, 2, 3...)

### 20231117

#### Windows support

Habu now works on Windows! Note that I'm not a daily Windows user myself, so I'm happy to hear about any bugs or weird behavior Windows users come across.

#### Add `stopped` modifier to chains.

Stopping a chain is useful when you are no longer interested in tracking it but you want to keep the history and stats around.
Use `modify <index> stopped <date>` to stop a chain, or `modify <index> stopped false` to make a stopped chain active.
Stopped chains are not displayed by default, and their stats only include the dates from the creation date up to the stopped date.
Also add a new `--show` parameter to choose which chains to display.

#### Minor features

- Add `habu version` command.

#### Bugfixes

- Compute stats for the entire chain in `info` command, not just the last 30 days.
- Fix args check for `habu help <command>`, it takes 1 optional arg, not 0.

### 20230810

- Initial release
