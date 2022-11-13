const std = @import("std");

const Command = @import("main.zig").Command;

pub const help_str =
\\Usage: habu add <name> <type> <min_days>
\\       habu delete <index>
\\       habu display [<end date>] | <start date> <end date>
\\       habu export
\\       habu help [command]
\\       habu import
\\       habu info <index> [<date>]
\\       habu link <range> [<date>] [<tags>...]
\\       habu modify <index> <field> <value> [<field> <value>...]
\\       habu tag <index> <date> <tag>
\\       habu unlink <range> [<date>]
\\
\\Options:
\\       --data-dir: absolute path to override where to read/write data files.
\\
\\Chain:
\\       A habit you want to track. The name comes from the "Don't break the chain" method of building
\\       habits, where the goal is to check off your habit every day and thus build of a long "chain"
\\       of checkmarks.
\\
\\Link:
\\       A checkmark of completion for a chain on a specific day.
\\
\\Index:
\\       Selects the chain for a command.
\\       Found in the left-most number in parenthesis in the output of the `display` command.
\\
\\Ranges:
\\       Select multiple chains
\\           1-5: includes 1,2,3,4 and 5
\\           1,3: includes 1 and 3
\\       Can be combined (duplicates are allowed): 1,3-5,2-4
\\
\\Dates:
\\       t, today      -   Today
\\       y, yesterday  -   Yesterday
\\       YYYYMMDD      -   Arbitrary date
\\
\\Tags:
\\       Links can be tagged to make your tracking more precise.
\\       For example, the chain 'Exercise' could have the tags 'gym', 'run' and 'swim'.
\\       Tags are added to a chain with the `modify` command, and to a link with the `link` or `tag` commands.
\\       You can add up to 4 tags per chain.
\\       Tags are added to links as a comma-sperated list: 'tag1,tag2,tag3'
\\
;

pub fn commandHelp(command: Command) ?[]const u8 {
    return switch (command) {
        .add    => \\ Adds a chain.
                   \\
                   \\ Examples:
                   \\
                   \\ `habu add Floss daily`
                   \\ Adds a chain name "Floss" that needs to be linked every day to be unbroken.
                   \\
                   \\ `habu add Exercise weekly 2`
                   \\ Adds a chain name "Exercise" that needs to be linked at least 2 times a week to be unbroken.
                   \\
                   ,
        .delete => \\ Deletes a chain. The chain index is the left-most number in the `display` command output.
                   \\
                   \\ Examples:
                   \\
                   \\ `habu delete 2`
                   \\ Deletes the chain with index 2.
                   \\
                   ,
        .@"export" => \\ Exports all chains and links to 'stdout' as JSON. The data can be imported back to the Habu format with the `import` command.
                      \\
                   ,
        .import => \\ Reads data created by the `export` command from 'stdin' and creates new files in the data folder with a `.imported` suffix.
                   \\ Since the imported files are created with a suffix, importing data never overwrites the primary data files, but it will overwrite
                   \\ any other imported data.
                   \\
                   \\ Examples:
                   \\
                   \\ Export your data to `data.json`
                   \\ `habu export > data.json`
                   \\
                   \\ Import `data.json` to `chains.bin.imported` and `links.bin.imported`
                   \\ `habu import < data.json`
                   \\
                   \\ Remove the suffix from the imported files so Habu will load them
                   \\ `cd .habu && mv chains.bin.imported chains.bin` && mv links.bin.imported links.bin`
                   \\
                   ,
        .modify    => \\ Modifies an attribute on an existing chain.
                      \\
                      \\ Attributes:
                      \\
                      \\   - name (max length 128)
                      \\   - type (daily/weekly)
                      \\   - min_days (1-7)
                      \\
                      \\ Examples:
                      \\
                      \\ Change the name of chain 2 to 'Another name'
                      \\ `habu modify 2 name 'Another name'`
                      \\
                      \\ Change the type of chain 1 from weekly to daily
                      \\ `habu modify 1 type daily`
                      \\
                      \\ Change the min_days of chain 3 to 5
                      \\ `habu modify 3 min_days 5`
                      \\
                    ,
        .link     => \\ Marks a chain as completed on the specified date.
                     \\
                     \\ See `habu help dates` for more information about date formats, and `habu help ranges` for the chain selection syntax.
                     \\
                     \\ Examples:
                     \\
                     \\ Link chain 1 today
                     \\ `habu link 1`
                     \\
                     \\ Link chain 2 yesterday
                     \\ `habu link 2 y` or `habu link 2 yesterday`
                     \\
                     \\ Link chain 1, 2, 3 and 5 on the 23rd of June
                     \\ `habu link 1-3,5 20230623`
                     \\
                     \\ Link chain 1 today with the tags 'exercise,run'
                     \\ `habu link 1 t exercise,run
                     \\
                    ,
     .unlink     => \\ Removes the completion of a chain on the specified date.
                    \\
                    \\ See `habu help dates` for more information about date formats, and `habu help ranges` for the chain selection syntax.
                    \\
                    \\ Examples:
                    \\
                    \\ Unlink chain 1 today
                    \\ `habu unlink 1`
                    \\
                    \\ Unlink chain 2 yesterday
                    \\ `habu unlink 2 y` or `habu link 2 yesterday`
                    \\
                    \\ Unlink chain 1, 2, 3 and 5 on the 23rd of June
                    \\ `habu unlink 1-3,5 20230623`
                    \\
                ,
     .info      => \\ Shows detailed information about a chain or a link.
                   \\
                   \\ Examples:
                   \\
                   \\ Show info for chain 2
                   \\ `habu info 2`
                   \\
                   \\ Show info for the link on 20230404 on chain 1
                   \\ `habu info 1 20230404`
                   \\
                ,
     else => null,
    };
}
