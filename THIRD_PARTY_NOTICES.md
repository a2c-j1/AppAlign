# Third-Party Notices

AppAlign is developed as an independent macOS application. Unless a file says otherwise, the AppAlign source in this repository remains under the repository's current "All rights reserved" notice.

## Microsoft PowerToys / FancyZones

AppAlign uses Microsoft PowerToys FancyZones as a product and architecture reference. Roadmap issues link to a fixed PowerToys revision so behavior can be studied reproducibly:

- Project: Microsoft PowerToys
- Component: FancyZones
- Reference revision: `1400fd8e999f381329e16e9df4084f7dc588c8a7`
- Upstream license: MIT
- Copyright: Microsoft Corporation and PowerToys contributors

At the AppAlign baseline revision `7bc28c7b0c84c5c960b323209eec711f8bdb8f86`, the repository does not contain copied PowerToys source code or copied constant/data tables. Merely studying behavior or architecture does not make PowerToys code part of AppAlign.

If a future change copies or adapts PowerToys source code, constants, or data tables, that change must:

1. Identify the upstream file and exact revision in the pull request.
2. Preserve the applicable copyright notice.
3. Preserve the MIT license notice required by the upstream license.
4. Record the incorporated material in this file before distribution.

The upstream PowerToys license is available at:
https://github.com/microsoft/PowerToys/blob/1400fd8e999f381329e16e9df4084f7dc588c8a7/LICENSE

## Package dependencies

The current AppAlign baseline has no third-party package dependencies. When a dependency is added, its required attribution and license notice should be recorded here before release.
