-- ==
-- input {
--   [ [ [ [1,2,3], [4,5,6] ]
--     ]
--   , [ [ [6,7,8], [9,10,11] ]
--     ]
--   , [ [ [3,2,1], [4,5,6] ]
--     ]
--   , [ [ [8,7,6], [11,10,9] ]
--     ]
--   ]
--   [3,3,3,3]
--   5
-- }
-- output {
--   [[[[2, 4, 6],
--      [8, 10, 12]]],
--    [[[12, 14, 16],
--      [18, 20, 22]]],
--    [[[6, 4, 2],
--      [8, 10, 12]]],
--    [[[16, 14, 12],
--      [22, 20, 18]]]]
-- }
let addRows (xs: []i32, ys: []i32): []i32 =
  map2 (+) xs ys

let main (xssss: [][][][]i32, cs: []i32, y: i32): [][][][]i32 =
  map  (\(xsss: [][][]i32, c: i32): [][][]i32  ->
         unsafe
         let yss = reshape (2,c) xsss in
         map  (\(xss: [][]i32): [][]i32  ->
                map (\(xs: []i32, ys: []i32): []i32  ->
                      addRows(xs,ys)
                   ) (zip  xss yss)
            ) xsss
      ) (zip  xssss cs)
