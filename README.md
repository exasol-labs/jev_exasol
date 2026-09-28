# Jev + Exasol

A collection of solutions built with [TypeSafe](https://typesafe.ai)'s **Jev**
model running inside Exasol as UDFs.

Jev answers a question about a piece of state and returns a calibrated
_probability_ rather than a string, so the answer can be used directly in SQL —
filtered, thresholded, joined, aggregated. Each solution here wires the TypeSafe
Python SDK into Exasol through a custom Script Language Container (SLC) and
applies Jev to a concrete dataset.

## Use cases

| Use case                                                         | What it does                                                                                           |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| [Invoice classification](usecases/invoice_classification/README.md) | Scores every invoice in a table against a plain-English yes/no question and returns the matching ones. |

Each use case is self-contained: its folder has the code, the data, and a
README with step-by-step deployment instructions.

## What you need

Every use case needs roughly the same setup. The details are in each use case's README.

- An Exasol database with admin rights. [Exasol Personal](https://www.exasol.com/personal/)
  is free if you don't have one.
- A TypeSafe API key from [console.typesafe.ai](https://console.typesafe.ai).
- Docker and WSL (or Linux/macOS) to build the Script Language Container.
- Outbound HTTPS access from the Exasol UDFs to `api.typesafe.ai`.
