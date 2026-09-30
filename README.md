# Decision models + Exasol

A collection of solutions built with **Decision models** such as [TypeSafe](https://typesafe.ai)'s **Jev** or OpenAI's Decision API making decisions on Exasol tables.

Decision models like **Jev** answer a question about a piece of state and returns a calibrated
_probability_ rather than a string, so the answer can be used directly in SQL —
filtered, thresholded, joined, aggregated. Each solution here wires the TypeSafe
Python SDK into Exasol through a custom Script Language Container (SLC) and
applies Jev to a concrete dataset.

## Use cases

| Use case                                                            | What it does                                                                                                                    |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| [Invoice classification](usecases/invoice_classification/README.md) | Scores every invoice in a table against a plain-English yes/no question and returns the matching ones.                          |
| [Entity resolution](usecases/entity_relation/README.md)             | Matches messy company records to the UK company register and finds duplicates, compared against a SQL string-matching baseline. |

Each use case is self-contained: its folder has the code, the data, and a
README with step-by-step deployment instructions.

## What you need

Every use case needs roughly the same setup. The details are in each use case's README.

- An Exasol database with admin rights. [Exasol Personal](https://www.exasol.com/personal/)
  is free if you don't have one. You can also use
  [Exasol Docker DB](https://github.com/exasol/docker-db) as an alternative.
- A TypeSafe API key from [console.typesafe.ai](https://console.typesafe.ai) or any other Decision model (e.g. Decision API from OpenAI).
- Docker and WSL (or Linux/macOS) to build the Script Language Container.
- Outbound HTTPS access from the Exasol UDFs to `API`.
