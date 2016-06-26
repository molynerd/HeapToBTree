# HeapToBTree
Script for converting heap tables to a b-tree (adds a clustered index).

## What do I need this for?
Here's the situation: You're working on a database and you notice there are some heaps that really deserve to be b-tree tables. You've done your research and deemed a clustered index is just what the doctor ordered. The problem is the actual doing of said change. That's where this script comes in.

# Usage
All you need to do is set the variables at the beginning of the script and run it. Could you make a stored procedure for this? Sure. My thought was that hopefully you wouldn't have to institutionalize this. Keep it in your toolset and break it out when you need to.

##### `@table_name`
The name of the table you're converting.
##### `@schema`
The schema the table you're converting exists in.
##### `@show_statements_only`
Set this to **1** to *prevent* any changes from occurring. The script will simply return a result set that contains, in order, the actions the script would have performed. Use this if you're feeling uncomfortable, you're debugging an issue, or you'd just plain like to know what's about to happen. Another reason to use this is if the table is massive and requires the change to be executed during a maintenance window or scheduled in the dead of night.

## Requirements
- The table must have a primary key (single or composite). The script has to know what column(s) to use when creating the clustered index.
- The table cannot be a system table. That would be weird. Don't do that.
- The table must be a heap. Essentially it has no clustered index.

## Testing
- SQL Server 2014

## TODO
- Add a testing suite. I'd like to get a series of tests to run so that one could easily run the test case on different versions of SQL Server and verify it works. It'll also help with adding any changes.
