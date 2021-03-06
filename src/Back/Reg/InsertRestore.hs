module Back.Reg.InsertRestore where

import           Algebra.Graph.AdjacencyMap as Galg
import           Algebra.Graph.AdjacencyMap.Algorithm
import           Algebra.Graph.AdjacencyMap.Internal
import           Back.Block
import           Back.Reg.SmallBlock
import           Data.Map                             as M
import           Data.Maybe                           (fromJust)
import           Data.Sequence                        as SEQ
import           Data.Set                             as S
import Data.Foldable as F
import           RunRun.Type                          as Type
import Data.List as L
import Control.Monad.State

type G = AdjacencyMap

mkGraph :: Map SN (Set SN) -> G SN
mkGraph = AM

forward :: G SN -> [SN]
forward = fromJust . topSort

type SetV = Set String

type Def = Map SN SetV
type Free = Map SN SetV
type TypeMap = Map String Type

-- |
-- 第一引数は, 1 つの 関数の smallblock 全体. SmallBlock.hs で生成.
--
-- 第二引数は, SmallBlock.hs で生成したグラフを mkGraph で変換したもの.
--
-- 第三引数は, 第二引数のグラフを topSort したもの.
collectDefFree :: Map SN SmallBlock -> G SN -> [SN] -> (Def, Free, TypeMap)
collectDefFree m g =
    Prelude.foldl (\ (def,free,oldtm) sn -> let (d,f,tm) = collect sn def in (d, M.insert sn f free, tm `M.union` oldtm))
      (M.empty, M.empty, M.empty)
    where
      reverseG = Galg.transpose g
      collect :: SN -> Def -> (Def, SetV, TypeMap)
      collect sn acc =
        (M.insert sn d acc, f, tm)
        where
          sb = m M.! sn
          instseq = sInst sb
          getparent = adjacencyMap reverseG M.! sn
          defparent = intersectL (S.foldr (\ parent b -> acc M.! parent : b) [] getparent)
          (d,f,tm) = instDef instseq (defparent, S.empty, M.empty)

-- | これ末尾仕様の考慮されてなくないか？
-- [XXX]
unionL :: [SetV] -> SetV
unionL = foldr1 S.intersection

intersectL :: [SetV] -> SetV
intersectL = foldr1 S.intersection

instDef :: InstSeq -> (SetV, SetV, TypeMap) -> (SetV, SetV, TypeMap)
instDef Empty s = s
instDef (i :<| is) (d, f, m)
    -- -- | ((x,Type.Float), Inst _ ys zs) <- i = f (d1, S.insert x d2) ys zs
    | ((x,t), Inst _ ys zs) <- i = func (S.insert x d) ys zs x t
    where
      func d ys zs x t =
        (d, (S.fromList ys S.\\ d) `S.union` (S.fromList zs S.\\ d) `S.union` f,
        M.insert x t m)



data Ref = Ref {
         graphG :: G SN,
         graphD :: G SN,
         listL:: [SN],
         mapFree :: Map SN SetV,
         mapDef :: Map SN SetV,
         set2S :: Set SN,
         set2f :: SetV,
         components :: [[SN]],
         revH :: G SN,
         xsets :: Map String (Set SN)
         }
type St = State Ref


refinit :: Ref
refinit = Ref {
         graphG = Galg.empty,
         graphD = Galg.empty,
         listL = [],
         mapFree = M.empty,
         mapDef = M.empty,
         set2S = S.empty,
         set2f = S.empty,
         components = [],
         revH = Galg.empty,
         xsets = M.empty}


searchTop :: G SN -> Free -> Def -> St ()
searchTop d free def = do
    let l = fromJust (topSort d)
        g = symmetricClosure d
    (\a -> put (a {graphG = g,
                   graphD = d,
                   listL = l,
                   mapFree = free,
                   mapDef = def}))  =<< get
    forConn


forConn :: St ()
forConn = do
    l <- gets listL
    when (l /= []) (do
           let u = L.head l
           g <- gets graphG
           let c = reachable u g
           d <- gets graphD
           let h = Galg.induce (`L.elem` c) d
               rh = Galg.transpose h
           let l' = [ x | x <- l, x `L.notElem` c ]
           free <- gets mapFree
           let f = unionL [free M.! v | v <- c ]
           cs <- gets components
           (\a -> put (a { listL = l',
                          set2f = f,
                          revH = rh,
                          components = c : cs})) =<< get
           eachx
           forConn)

eachx :: St ()
eachx = do
    f <- gets set2f
    unless (S.null f) (do
          free <- gets mapFree
          let (x, newf) = S.deleteFindMin f
              s = keysSet (M.filter (x `S.member`) free)
          l <- gets listL
          let revl = L.reverse l
          (\ a -> put (a {set2f = newf, set2S = s})) =<< get
          pathsearch x revl M.empty
          m <- gets xsets
          s <- gets set2S
          let newm =  M.insert x s m
          (\ a -> put (a {xsets = newm})) =<< get)

pathsearch :: String -> [SN] -> Map SN SN -> St ()
pathsearch x l m = do
    s <- gets set2S
    revh <- gets revH
    case s of
      _ | [] <- l -> return ()
        | v:vs <- l, velems v, Just u <- maybeu v -> changes u x
        | v:vs <- l, Just u <- maybeu v -> writeparents u v vs
        | v:vs <- l, velems v -> writeparents v v vs
        | v:vs <- l -> pathsearch x vs m
        where
          velems v = v `S.member` s
          maybeu v = M.lookup v m
          writeparents u v vs = do -- u を v の親に.
                let newm = S.foldr (\ p -> insertWith (const id) p u) m (postSet v revh)
                pathsearch x vs newm

changes :: SN -> String -> St ()
changes v x = do
    s <- gets set2S
    parents <- gets (postSet v . revH)
    def <- gets mapDef
    let s' = S.foldr (insertif def) (S.delete v s) parents
    (\ a -> put (a { set2S = s' })) =<< get
    where
      insertif def p s
        | S.notMember x (def M.! p) = S.insert p s
        | otherwise = s



--  xsets :: Map String (Set SN)
reverseRestore :: Map String (Set SN) -> Map SN a -> Map SN (Set String)
reverseRestore m = -- 第二引数は適当でいい. SN の集合が欲しいだけ.
    M.mapWithKey (\ sn _ -> collectString sn)
    where
      collectString sn =
        M.foldrWithKey (\ k setsn acc -> if sn `elem` setsn then S.insert k acc else acc) S.empty m

insertRestore :: Map SN SmallBlock -> G SN -> [SN] -> (Map SN SmallBlock, [[SN]])
insertRestore snsbmap g sorted =
    let (def, free, tm) = collectDefFree snsbmap g sorted
        (_, ref) = runState (searchTop g free def) refinit
        transformer = reverseRestore (xsets ref) snsbmap in
    (transform transformer snsbmap tm, L.reverse (components ref))
--       (restoredsnsbmap, clist) = insertRestore.insertRestore snsbmap sngraph topsort

transform :: Map SN (Set String) -> Map SN SmallBlock -> TypeMap -> Map SN SmallBlock
transform op snsb tm =
    M.mapWithKey (\ sn sb -> transInstSeq tm (op M.! sn) sb) snsb


transInstSeq :: TypeMap -> Set String -> SmallBlock -> SmallBlock
transInstSeq tm s sb =
    let (s', instseq) = F.foldr transOneInst (s, SEQ.Empty) inst
    in
      sb { sInst = cat s' instseq }
    where
      inst = sInst sb
      -- sInst :: InstSeq, sBranch :: SmallBlockTail, sIsCall :: Bool}
      transOneInst :: ((String, Type), Inst) -> (Set String, InstSeq) -> (Set String, InstSeq)
      transOneInst i@(_, Inst _ ys zs) (ss, instacc) =
          let restore  =
                S.foldr (\ y acc -> ((y,Type.Int), Inst (Restore y) [] []) <| acc) SEQ.Empty ysRestore
              restore' =
                S.foldr (\ z acc -> ((z,Type.Float), Inst (Restore z) [] []) <| acc) restore zsRestore
          in
            (ss', instacc >< (restore' |> i))
          where
            ysRestore = S.fromList ys `S.intersection` ss
            ss' = ss S.\\ ysRestore
            zsRestore = S.fromList ys `S.intersection` ss'
            ss'' = ss' S.\\ zsRestore
      cat :: Set String -> InstSeq -> InstSeq
      cat s instseq =
        let i' = S.foldr (\ y acc -> ((y,gettype y), Inst (Restore y) [] []) <| acc) instseq s
        in instseq >< i'
        where
          gettype x = tm M.! x



-- collectDefFree :: Map SN SmallBlock -> G SN -> [SN] -> (Def, Free)
--       (restoredsnsbmap, clist) = insertRestore.insertRestore snsbmap sngraph topsort



-- data Ref = Ref {
--          graphG :: G SN,
--          graphD :: G SN,
--          listL:: [SN],
--          mapFree :: Map SN SetV,
--          mapDef :: Map SN SetV,
--          set2S :: Set SN,
--          set2f :: SetV,
--          components :: [[SN]],
--          revH :: G SN,
--          xsets :: Map String (Set SN)
--          }
