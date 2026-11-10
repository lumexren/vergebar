// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of vergebar.
//
// Copyright (c) 2026 lumexren
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://gnu.org/licenses>.

const PhysicalMemoryInfo = @This();

total: u64 = 0,
free: u64 = 0,
available: u64 = 0,
used: u64 = 0,
buffers: u64 = 0,
cached: u64 = 0,
shared: u64 = 0,

active: u64 = 0,
inactive: u64 = 0,
active_anon: u64 = 0,
inactive_anon: u64 = 0,
active_file: u64 = 0,
inactive_file: u64 = 0,

anon_pages: u64 = 0,
mapped: u64 = 0,

slab: u64 = 0,
slab_reclaimable: u64 = 0,
slab_unreclaimable: u64 = 0,
kernel_reclaimable: u64 = 0,

kernel_stack: u64 = 0,
page_tables: u64 = 0,
sec_page_tables: u64 = 0,
percpu: u64 = 0,

dirty: u64 = 0,
writeback: u64 = 0,
writeback_tmp: u64 = 0,
unevictable: u64 = 0,
mlocked: u64 = 0,

anon_huge_pages: u64 = 0,
file_huge_pages: u64 = 0,
file_pmd_mapped: u64 = 0,
shmem_huge_pages: u64 = 0,
shmem_pmd_mapped: u64 = 0,
hugetlb: u64 = 0,
hugepages_size: u64 = 0,

direct_map_4k: u64 = 0,
direct_map_2m: u64 = 0,
direct_map_1g: u64 = 0,

vmalloc_total: u64 = 0,
vmalloc_used: u64 = 0,
vmalloc_chunk: u64 = 0,
hardware_corrupted: u64 = 0,
bounce: u64 = 0,
nfs_unstable: u64 = 0,
cma_total: u64 = 0,
cma_free: u64 = 0,
unaccepted: u64 = 0,
balloon: u64 = 0,
