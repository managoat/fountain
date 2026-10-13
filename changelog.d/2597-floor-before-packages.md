### Security

- A cold provision applies the environment's network policy before it installs the environment's packages (#2597). The apt and npm commands run with the conversation's process environment, so they no longer run on the provider's open network before the floor lands. A `limited` environment must list its package mirrors in `allowed_hosts`; one that lists packages without them now fails at the `packages` stage instead of installing them unrestricted.
