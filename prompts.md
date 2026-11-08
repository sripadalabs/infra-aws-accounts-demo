## Repositories and module order

1. **Core network foundation/orchestration** (`infra-aws-core-networks`)
   - Manage the organization’s AWS VPC IPAM configuration and pool hierarchy, including the top-level pool and regional pools. Use the CIDR plan below as configurable example input, not hardcoded module behavior.
   - Invoke the `terraform-aws-transitgateway` module once per configured region to create that region’s TGW and east-west/north-south route tables.
   - Create and manage inter-region TGW peering attachments between configured regional TGWs, including accepter-side acceptance where required.
   - Configure static TGW routes in the appropriate regional route tables for destinations reachable through each peering attachment. TGW peering does not automatically propagate routes; route destinations and route-table associations must be explicit inputs.
   - Support configurable peering topology (for example, full mesh or selected peer pairs) and avoid creating duplicate peerings.
   - Keep IPAM pools, TGWs, peerings, and routes in the correct AWS Regions. Make account/region assumptions explicit.
   - Output typed maps of regional IPAM pool IDs, TGW IDs, TGW route table IDs, peering attachment IDs, and route IDs as appropriate.
   - Define this repository as the owner of the IPAM pool hierarchy, inter-region peering, and cross-region TGW routes. The invoked TGW module owns each regional TGW and its route tables; do not duplicate those resources in this repository.

2. **Transit Gateway module** (`terraform-aws-transitgateway`)
   - Provide a reusable module that creates one regional TGW and its east-west and north-south route tables.
   - Accept region-specific settings and expose typed TGW ID and route table IDs.
   - Support attachment options required by the selected architecture, including appliance mode where appropriate.
   - Do not create inter-region peerings or cross-region routes; those are managed by `infra-aws-core-networks`.

3. **VPC module** (`terraform-aws-vpc`)
   - Create a VPC using exactly one allocation mode:
     1. Explicit CIDR: set `cidr_block`; leave `ipv4_ipam_pool_id` and `ipv4_netmask_length` unset.
     2. IPAM allocation: set both `ipv4_ipam_pool_id` and `ipv4_netmask_length`; leave `cidr_block` unset.
   - Reject configurations that set both allocation modes or neither. Validate the mutually exclusive inputs and document the required fields for each mode.
   - Do not create an IGW or subnet route tables in this module.
   - Enable VPC Flow Logs to S3 using the configured bucket ownership approach.
   - Output typed VPC ID and actual allocated VPC CIDR.

4. **Subnet/networking module** (`terraform-aws-vpc-networking`)
   - Accept VPC ID and CIDR from the VPC module.
   - Accept a typed map of subnet objects keyed by subnet name. Each object specifies at least subnet type, availability zone, and CIDR, with explicit optional fields for NAT and custom routes.
   - Support subnet types: `public`, `private-only`, `private-with-internet`, `networking`, `private-with-nat`, and `private-with-private-nat`.
   - Create subnets, route tables, associations, IGW, and NAT Gateways according to the agreed design. State whether route tables are per subnet or shared and implement that consistently.
   - Output typed subnet IDs grouped by type and AZ, route table IDs, IGW ID (nullable when absent), and NAT Gateway IDs.
   - Do not manage cross-module routes that require firewall or TGW outputs; those belong to the root composition unless explicitly assigned elsewhere.

5. **AWS Network Firewall module** (`terraform-aws-nw-firewall`)
   - Create firewall resources using dedicated subnet IDs supplied by the networking module; do not create or own those subnets or their route tables.
   - Expose endpoint IDs keyed by AZ.
   - Do not modify route tables owned by another module. Output IDs needed for route composition.

6. **VPC attachment module** (`terraform-vpc-tran-gw-attachment`)
   - Accept VPC ID, TGW ID, and the specified attachment subnet IDs.
   - Configure attachment options, association, and propagation to selected regional TGW route tables.
   - Output typed attachment ID and values needed by route composition.

## Resource ownership and composition

- `infra-aws-core-networks` owns IPAM pools, regional TGW module instantiations, TGW peerings, and cross-region TGW routes.
- `terraform-aws-transitgateway` owns each regional TGW and its route tables.
- The VPC module owns the VPC and Flow Logs configuration.
- The networking module owns subnets, IGW, NAT Gateways, subnet route tables, and subnet-to-route-table associations.
- The firewall module owns firewall resources and firewall endpoint IDs.
- The attachment module owns VPC TGW attachments, associations, and propagations.
- Root configuration owns only cross-module routes that need outputs from multiple modules and are not owned by `infra-aws-core-networks`. No AWS resource may be managed by more than one module.
- Show regional and inter-region route composition explicitly. For TGW peering, create static routes in the relevant TGW route tables pointing to the peering attachment; do not assume route propagation across the peering.
- Ensure route ownership and module dependencies do not create cycles. Document the complete route path, including return routes and AZ-specific firewall routing where required.