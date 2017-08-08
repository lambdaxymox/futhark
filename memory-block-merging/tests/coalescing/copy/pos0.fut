-- Memory block merging with a copy.  Requires allocation hoisting of the memory
-- block for 't1'.
-- ==
-- input { [7, 0, 7] }
-- output { [8, 1, 8] }
-- structure cpu { Alloc 1 }
-- structure gpu { Alloc 1 }

import "/futlib/array"

let main (ns: [#n]i32): [n]i32 =
  let t0 = map (+ 1) ns -- Will use the memory of t1.
  let t1 = copy t0
  in t1
