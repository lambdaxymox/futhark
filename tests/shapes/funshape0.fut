-- ==
-- input { [1,-2,3] } output { 3i64 }

let f [n] (_: [n]i32 -> i32) : [n]i32 -> i64 =
  let m = n + 1
  in \_ -> m

let main xs = filter (>0) xs |> f (\_ -> 0)
