# ETX App Platform Tooling

Utility scripts and tools for the ETX App Platform workshop.

## Scripts

### enroll-secondary-cluster.sh

Enrolls a secondary OpenShift cluster with the primary cluster's ArgoCD instance for multi-cluster deployment scenarios.

**Use Case**: Promotion pipeline lab where applications are deployed from factory cluster to runtime cluster.

**Usage**: See [enrollment documentation](docs/enrollment.md)

## Documentation

- [Cluster Enrollment Guide](docs/enrollment.md)

## Repository Structure

```
etx_app_tooling/
├── scripts/
│   └── enroll-secondary-cluster.sh    # Cluster enrollment automation
├── docs/
│   └── enrollment.md                   # Enrollment documentation
└── README.md
```

## License

Apache 2.0
