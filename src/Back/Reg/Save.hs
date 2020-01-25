module Back.Reg.Save where

import           Back.Block
import           Data.Map      as M
import           Data.Sequence as SEQ
import           Data.Set      as S
import           RunRun.RunRun

type Live = Seq (Set String, Set String)
type SaveSet = (Set String, Set String)


-- | collect variables that are to be saved.
saveset :: Map String (FunctionData, Map Int Live) -> RunRun (Map String (FunctionData, Map Int Live, SaveSet))
saveset m =
    return $ M.map (\ (f,x) -> (f,x,saveFunc f x)) m


saveFunc :: FunctionData -> Map Int Live -> SaveSet
saveFunc func livemap =
    Prelude.foldr g (S.empty, S.empty) (line func)
    where
      f n = saveBlock (blocks func M.! n) (livemap M.! n)
      g n s = f n `union2` s

-- | can not handle with tailCall yet
saveBlock:: Block -> Live -> SaveSet
saveBlock block live =
    let s =
          -- case blockTailExp block of
          --        Call ->
          (S.empty, S.empty)
    in
    s `union2` saveSeq (blockInst block) live


saveSeq :: InstSeq -> Live -> SaveSet
saveSeq Empty _               = (S.empty, S.empty)
saveSeq (x :<| xs) (y :<| ys) = save x y `union2` saveSeq xs ys
saveSeq _ _                   = (S.empty, S.empty) -- should be an error

save :: ((String, a), Inst) -> SaveSet -> SaveSet
save ((_,_), Inst (CallDir _) _ _) s = s


-------------------
-- util
-------------------
union2 :: SaveSet -> SaveSet -> SaveSet
union2 (a,b) (c,d) = (a `S.union` c, b `S.union` d)

