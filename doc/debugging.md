# Debugging and troubleshooting
## Outline

Both `fisdat(1)` and `fisup(1)` print messages to the terminal. There are a few things we can use to debug behaviour.

## Disabling validation

`fisdat(1)` has the `--no-validate` (`-n` for short) option. This will add a given data file and nominally associated schema, without using LinkML to validate the schema proper. This is primarily useful if your data are not in CSV format and you are only interested in uploading it (without doing any validation by running any jobs), but it may also be useful for circumstances in which LinkML fails to validate files which are valid (e.g. treatment of missing data is an open issue).

`fisup(1)` does not validate data files against associated schema files, but it does convert YAML schema files to TTL, i.e. there are a number of circumstances in which it is effectively validating that the schema files are valid YAML. The `--no-convert-schema` option is useful in these circumstances.

## Disabling uploads and simulating `fisup(1)` behaviour

`fisup(1)` has several related options:
- `--no-convert-schema`, which we have already encountered;
- `--no-upload`, which performs conversion of schema files and the manifest file, but only simulates upload;
- `--dry-run`, which simulates all operations, and does not write to the file-system.

Originally, there was only the single "dry run" option, simulating everything, but it became apparent that being able to test changes locally was very useful. There is a further, related option of note here, `--force`. The current behaviour is, during conversion, not to overwrite files which had already been converted, but this option overrides that.

## Verbose logging

There are two log levels common to both `fisdat(1)` and `fisup(1)`:
- `--verbose` (or `-v` for short), which sets the internal log level to "INFO" and shows debug messages by functions
- `--extra-verbose` (or `-vv` for short), which sets the internal log level to "DEBUG" and shows considerably more log messages, including those generated by LinkML, RDFLib, &c. 

The main intent behind adding these, especially the most verbose option, is to aid debugging when reporting issues on the issue tracker. Log messages tend to be quite long and may not be very informative.

In general, the messages printed to the terminal by the program try to make it fairly obvious which step has failed. Many Python programs show traces upon raising errors, whereas this one largely does not. (The errors are caught and messages in plainer language are printed instead.) The reason for this is that most of the errors were associated with the LinkML library which we are using, and were fairly non-specific, because they actually related to some of the libraries underneath (such as conversion between JSON-LD and RDF, or serialisation with RDFLib proper), and their interaction with network resources. 

## Dealing with missing data

There is an outstanding issue with missing data, at least as far as us using LinkML goes. Whereas Python libraries like Pandas have a distinct notion of missing data (R and Pandas tend to use `NA` for this), and treat it differently from error state, the LinkML during validation does not accept these labels (it accepts an absolute empty field in CSV data only), and treats these fields as missing as equivalent to the column proper being optional.

While this is certainly not ideal, and [we opened an issue on the library's issue tracker](https://github.com/linkml/linkml/issues/1994) to discuss this with them, at least in terms of validating data files, at least in terms of validating the data we already have, the workaround is fairly straightforward:
1. Replace "NA" labels with an empty field
2. In the associated schema files, set `required: false` for any columns which may have missing data

A sample R script `prep.R` showing how one might do this is included in the sentinel cages example, using the `write_tables()` function, since this allows more control over the separator and treatment of the label for missing data (set it to ''). The `sentinel_cages_cleaned.csv` file in that directory is the product of calling that script on the original `Sentinel_cage_sampling_info_update_01122022.csv` file.

While not necessarily desirable, subsequent processing of the data doesn't depend on LinkML (validation is with these local `fisdat(1)` and `fisup(1)`), the other option is to disable validation locally, since the initial ODE density/count model will accept any of the labels for missing data accepted by Pandas.