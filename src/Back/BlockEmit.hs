module Back.BlockEmit where

import           Data.Array             ((!))
import           Data.Int               ()
import           Data.List              (elemIndex, partition)
import qualified Data.Map               as M
import           Data.Set               (Set, empty, insert, notMember)
import           Prelude                hiding (exp, seq, tail)
import           System.IO
import           Text.Printf            (printf)
-- import Data.Char(toLower)
import           Control.Monad.IO.Class ()
import           Control.Monad.State
-- import Asm
import           RunRun.RunRun
-- import Data.Bits as B
import           Front.Syntax           (Compare (..))
import           Middle.Closure_Type    (L (L))
import           RunRun.Type            as Type (Type (..))

import           Back.Block

import           Foreign.C.Types

foreign import ccall "getlo" c_getlo :: CFloat -> IO CShort
foreign import ccall "gethi" c_gethi :: CFloat -> IO CShort

getlo :: Float -> IO Int
getlo = fmap fromIntegral . c_getlo . realToFrac
gethi :: Float -> IO Int
gethi = fmap fromIntegral . c_gethi . realToFrac


-- stackset = いま格納されている変数の集合.
-- stackmap = stack 内での積む順番位置. どこで格納されても関数内で同じ変数は同じ位置に.
stackadd :: String -> RunRun ()
stackadd x = do
    f <- get
    put $ f {stackset = insert x (stackset f)}

-- stackmap_append :: String -> RunRun ()
-- stackmap_append x = do
--     f <- get
--     put $ f {stackmap = (stackmap f) ++ [x]}

save :: String -> RunRun ()
save x = -- do
    stackadd x
    -- eprint x
    -- smap <- stackmap <$> get
    -- if notElem x $ smap then
    --     stackmap_append x
    -- else
    --     return ()

--savef = save

locate :: String -> RunRun (Maybe Int)
locate x = do
    smap <- gets stackmap
    return $ elemIndex x smap

offset :: String -> RunRun Int
offset x = do
    mn <- locate x
    case mn of
        Just n  -> return $ n * 4
        Nothing -> throw $ Fail $ "what!? " ++ x

stacksize :: RunRun Int
stacksize = (*4) . (+1) . length <$> gets stackmap



shuffle :: Eq a => a -> [(a, a)] -> [(a, a)]
shuffle sw xys
    | ([],[]) <- tmp = []
    | ((x,y):xys'',[]) <- tmp
            = (y,sw) : (x,y) : shuffle sw (map (tmpfunc sw y) xys'')
    | (xys'', acyc) <- tmp = acyc ++ shuffle sw xys''
    where
        (_,xys') = partition (uncurry (==)) xys
        tmp = partition (\(_,y) -> mem_assoc y xys') xys'
        mem_assoc k = any (\(k',_) -> k'==k)
        tmpfunc sw' y ys@(y',z)
            | y == y' = (sw',z)
            | otherwise = ys

data Dest = Tail | NonTail String


-- data FunctionData = FunctionData {
--                   blocks :: M.Map Int Block,
--                   blockgraph :: G.Graph,
--                   line :: [Int],
--                   args :: ![String],
--                   fargs :: ![String],
--                   ret :: !Type
--                   }
-- funcGraph :: Map String Graph
printFunc :: Handle -> String -> FunctionData -> RunRun ()
printFunc oc funcname funcdata = do
        liftIO $ hPutStr oc $ printf "%s:\n" funcname
        (\f -> put (f {stackset=empty, stackmap= allStack funcdata})) =<< get
        printBlocks oc (line funcdata) (blocks funcdata)


printBlocks :: Handle -> [Int] -> M.Map Int Block -> RunRun ()
printBlocks oc list bmap =
    mapM_ (\n -> printBlock oc n (bmap M.! n)) list


printBlock :: Handle -> Int -> Block -> RunRun ()
printBlock oc b Block {blockInst = seq, blockTailExp = tail, blockBranch = branch, blockStack = (bs,_)}
    | End <- tail, None <- branch = do
            instructions
            liftIO $ hPutStr oc $ printf "    jr %s\n" (reg reg_lr)
    | If x <- tail, Two b1 b2 <- branch = do
            instructions
            liftIO $ hPutStr oc $ printf "    bne %s r0 %s\n" (reg x) ("block_" ++ show b2)
            liftIO $ hPutStrLn oc $ printf "    j %s" ("block_" ++ show b1)
    | IfCmp cmp x y <- tail, Two _ b2 <- branch = do
            instructions
            case cmp of
                Eq  -> liftIO $ hPutStr oc $ printf "    beq %s %s %s\n" (reg x) (reg y) ("block_" ++ show b2)
                Ne  -> liftIO $ hPutStr oc $ printf "    bne %s %s %s\n" (reg x) (reg y) ("block_" ++ show b2)
                Gt  -> liftIO $ hPutStr oc $ printf "    blt %s %s %s\n" (reg y) (reg x) ("block_" ++ show b2)
                Lt  -> liftIO $ hPutStr oc $ printf "    blt %s %s %s\n" (reg x) (reg y) ("block_" ++ show b2)
            -- liftIO $ hPutStrLn oc $ printf "    j %s" ("block_" ++ show b1)
    | FIfCmp cmp x y <- tail, Two _ b2 <- branch = do
            instructions
            case cmp of
                Eq  -> do
                          liftIO $ hPutStr oc $ printf "    fsub %s %s %s\n" (reg reg_ftmp) (reg x) (reg y)
                          liftIO $ hPutStr oc $ printf "    fcz %s\n" (reg reg_ftmp)
                          liftIO $ hPutStr oc $ printf "    bc1t %s\n" ("block_" ++ show b2)
                Ne  -> do
                          liftIO $ hPutStr oc $ printf "    fsub %s %s %s\n" (reg reg_ftmp) (reg x) (reg y)
                          liftIO $ hPutStr oc $ printf "    fcz %s\n" (reg reg_ftmp)
                          liftIO $ hPutStr oc $ printf "    bc1f %s\n" ("block_" ++ show b2)
                Lt  -> do
                          liftIO $ hPutStr oc $ printf "    fclt %s %s\n" (reg x) (reg y)
                          liftIO $ hPutStr oc $ printf "    bc1t %s\n" ("block_" ++ show b2)
                Gt  -> do
                          liftIO $ hPutStr oc $ printf "    fclt %s %s\n" (reg y) (reg x)
                          liftIO $ hPutStr oc $ printf "    bc1t %s\n" ("block_" ++ show b2)
            -- liftIO $ hPutStrLn oc $ printf "    j %s" ("block_" ++ show b1)
    | End <- tail, One b1 _ _ <- branch = do
            instructions
            liftIO $ hPutStr oc $ printf "    j %s\n" ("block_" ++ show b1)
    | otherwise = throw $ Fail (show tail ++ show branch)
    where
      instructions = do
        (\a -> put (a {stackset = bs})) =<< get
        liftIO $ hPutStr oc $ printf "%s:\n" ("block_" ++ show b)
        mapM_ (printSeq oc) seq



printSeq :: Handle -> ((String, Type), Inst) -> RunRun ()
printSeq oc e@((x,_), Inst exp ys zs)
    | FLi f     <- exp = do
            n <- liftIO $ getlo f
            m <- liftIO $ gethi f
            let r = reg x
            liftIO $ hPutStr oc $ printf "    #%f\n" f
            liftIO $ hPutStr oc $ printf "    flui %s %d\n" r n
            when (m /= 0) $
                liftIO $ hPutStr oc $ printf "    fori %s %s %d\n" r r m
    | In t1 <- exp, t1 /= Int, t1 /= Float = throw $ Fail "input is only available for int and float."
    | Save _  <- exp = printSeqSave oc e =<< gets stackset
    | Restore y <- exp, x `elem` allregs = do
            ofset <- offset y
            liftIO $ hPutStr oc $ printf "    lw %s %s %d\n" (reg x) (reg reg_sp) ofset
    | Restore y <- exp, x `elem` allfregs = do
            ofset <- offset y
            liftIO $ hPutStr oc $ printf "    lwcZ %s %s %d\n" (reg x) (reg reg_sp) ofset
    | Restore _ <- exp = throw $ Fail "my god ..."
    | Makearray t' n' <- exp =
            printSeqArray oc t' x n' ys zs
    | CallDir (L func) <- exp = do
            mvArgs oc [] ys zs
            ss <- stacksize
            liftIO $ hPutStr oc $ printf "    sw %s %s %d\n"    (reg reg_lr) (reg reg_sp) (ss - 4)
            liftIO $ hPutStr oc $ printf "    addi %s %s %d\n"  (reg reg_sp) (reg reg_sp) ss
            liftIO $ hPutStr oc $ printf "    jal %s\n" func
            liftIO $ hPutStr oc $ printf "    subi %s %s %d\n"  (reg reg_sp) (reg reg_sp) ss
            liftIO $ hPutStr oc $ printf "    lw %s %s %d\n"    (reg reg_lr) (reg reg_sp) (ss - 4)
            if x `elem` allregs && x /= regs ! 0 then
                liftIO $ hPutStr oc $ printf "    mv %s %s\n"   (reg x) (reg $ regs ! 0)
            else when (x `elem` allfregs && x /= fregs ! 0) $
                liftIO $ hPutStr oc $ printf "    fmv %s %s\n"   (reg x) (reg $ fregs ! 0)
    | otherwise = liftIO $ hPutStr oc $ printinstruction e


printSeqSave :: Handle -> ((String, Type), Inst) -> Set String -> RunRun ()
printSeqSave oc ((_, _), Inst (Save y) [x] []) stset
    | x `elem` allregs, tf    = do
            save y
            ofset <- offset y
            liftIO $ hPutStr oc $ printf "    sw %s %s %d\n" (reg x) (reg reg_sp) ofset
    | x `elem` allfregs = throw $ Fail "so-nansu"
--    -- iranai hazu
--    -- | x `elem` allregs    = do
--    --         save y
--    --         ofset <- offset y
--    --         liftIO $ hPutStr oc $ printf "    sw %s %s %d\n" (reg x) (reg reg_sp) ofset
--    -- | x `elem` allfregs   = do
--    --         save y
--    --         ofset <- offset y
--    --         liftIO $ hPutStr oc $ printf "    swcZ %s %s %d\n" (reg x) (reg reg_sp) ofset
   | not tf                = return ()
    where
        tf = notMember y stset
printSeqSave oc ((_, _), Inst (Save y) [] [x]) stset
    | x `elem` allfregs, tf   = do
            save y
            ofset <- offset y
            liftIO $ hPutStr oc $ printf "    swcZ %s %s %d\n" (reg x) (reg reg_sp) ofset
    | x `elem` allregs = throw $ Fail "so-nano"
--    -- iranai hazu
--    -- | x `elem` allregs    = do
--    --         save y
--    --         ofset <- offset y
--    --         liftIO $ hPutStr oc $ printf "    sw %s %s %d\n" (reg x) (reg reg_sp) ofset
--    -- | x `elem` allfregs   = do
--    --         save y
--    --         ofset <- offset y
--    --         liftIO $ hPutStr oc $ printf "    swcZ %s %s %d\n" (reg x) (reg reg_sp) ofset
   | not tf                = return ()
-- printSeqSave oc ((_, _), Inst (Save y) [] [x]) stset
    | otherwise             = throw $ Fail "maji!?"
    where
        tf = notMember y stset
printSeqSave _ _ _ = throw $ Fail "e?"



mvArgs :: Handle -> [(String, String)] -> [String] -> [String] -> RunRun ()
mvArgs oc x_reg_cl ys zs = do
        let (_, yrs) = (\f -> foldl f (0,x_reg_cl) ys)
                (\(i,yrs') y -> (i+1, (y,regs ! i) : yrs'))
        mapM_ (\(y,r) ->
            liftIO $ hPutStr oc $ printf "    mv %s %s\n" (reg r) (reg y))
            (shuffle reg_sw yrs)
        let (_, zrs) = (\f -> foldl f (0,[]) zs)
                (\(d,zrs') z -> (d+1, (z,fregs ! d) : zrs'))
        mapM_ (\(z,fr) ->
            liftIO $ hPutStr oc $ printf "    fmv %s %s\n" (reg fr) (reg z))
            (shuffle reg_fsw zrs)


printSeqArray :: Handle -> Type -> String -> Id_or_imm -> [String] -> [String] -> RunRun ()
printSeqArray oc t x V ["%r0", v] [] = printSeqArray oc t x (C 0) [v] []
printSeqArray oc t x V ["%r0"] [v] = printSeqArray oc t x (C 0) [] [v]
printSeqArray oc t x V ys zs =
    let (n,v) = case (ys, zs) of
              ([n',v'],[]) -> (n', v')
              ([n'], [v']) -> (n', v')
              _            -> ("error","error") in
    do
            loop <- genid "arrayloop"
            exit <- genid "arrayexit"
            liftIO $ hPutStr oc $ printf "    beq r0 %s %s\n"   (reg n) exit
            liftIO $ hPutStr oc $ printf "    sll %s %s  2\n"   (reg reg_tmp) (reg n)
            liftIO $ hPutStr oc $ printf "%s:\n"                loop
            liftIO $ hPutStr oc $ printf "    subi %s %s 4\n"   (reg reg_tmp) (reg reg_tmp)
            case t of
                    Type.Float ->
                        liftIO $ hPutStr oc $ printf "    fswab %s %s %s\n" (reg v) (reg reg_hp) (reg reg_tmp)
                    _ ->
                        liftIO $ hPutStr oc $ printf "    swab %s %s %s\n"  (reg v) (reg reg_hp) (reg reg_tmp)
            liftIO $ hPutStr oc $ printf "    bne r0 %s %s\n"   (reg reg_tmp) loop
            liftIO $ hPutStr oc $ printf "    sll %s %s  2\n"   (reg reg_tmp) (reg n)
            liftIO $ hPutStr oc $ printf "    mv %s %s\n"       (reg x) (reg reg_hp)
            liftIO $ hPutStr oc $ printf "    add %s %s %s\n"   (reg reg_hp) (reg reg_hp) (reg reg_tmp)
            liftIO $ hPutStr oc $ printf "%s:\n"                exit
printSeqArray oc t x (C n) ys zs
    | [v] <- ys = f v
    | [v] <- zs = f v
    | otherwise = throw $ Fail "hyoeee"
    where f v = do
            forM_ [0..(n-1)] $ \ofset ->
                    case t of
                            Float -> liftIO $ hPutStr oc $
                                    printf "    swcZ %s %s %d\n" (reg v) (reg reg_hp) (4 * ofset)
                            _     -> liftIO $ hPutStr oc $
                                    printf "    sw %s %s %d\n" (reg v) (reg reg_hp) (4 * ofset)
            liftIO $ hPutStr oc $ printf "    mv %s %s\n" (reg x) (reg reg_hp)
            liftIO $ hPutStr oc $ printf "    addi %s %s %d\n" (reg reg_hp) (reg reg_hp) (n * 4)



emit :: Handle -> M.Map String FunctionData -> RunRun ()
emit oc functions = do
    eputstrln "blockemit ..."
    -- eprint functions
    eputstrln "assembly"
    stack <- gets sp
    heap  <- gets hp
    --eprint =<< (globals <$> get)
    liftIO $ hPutStr oc $ printf "    ori %s r0 %d\n" (reg reg_sp) stack
    liftIO $ hPutStr oc $ printf "    ori %s r0 %d\n" (reg reg_hp) heap
    liftIO $ hPutStr oc $ printf "    jal main\n"
    liftIO $ hPutStr oc $ printf "end_of_program:\n    nop\n"
    liftIO $ hPutStr oc $ printf "    beq r0 r0 end_of_program\n"
    f <- get
    put $ f { stackset = empty, stackmap = [] }
    -- g oc (NonTail "R0", e)

    sequence_$ M.mapWithKey (printFunc oc) functions
    --global <- globals <$> get
    --liftIO $ hPrint stdout global


