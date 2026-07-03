# Kafka Platform Docs

OpenShift-focused Kafka documentation lives at:

- [openshift/README.md](openshift/README.md)

This package includes a namespace-scoped Kafka KRaft deployment model:

- no operator
- no cluster-admin dependency for deployment
- no ZooKeeper
- StatefulSet + headless service + PVC
