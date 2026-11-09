import sys
R = {'add':(0,0),'sub':(0,0x20),'sll':(1,0),'slt':(2,0),'sltu':(3,0),'xor':(4,0),'srl':(5,0),'sra':(5,0x20),'or':(6,0),'and':(7,0)}
def reg(t): return int(t.strip('x'))
def enc(op, a):
    if op in R:
        f3,f7 = R[op]
        return (f7<<25)|(reg(a[2])<<20)|(reg(a[1])<<15)|(f3<<12)|(reg(a[0])<<7)|0x33
    if op=='addi': return (int(a[2],0)<<20)|(reg(a[1])<<15)|(0<<12)|(reg(a[0])<<7)|0x13
    if op=='lw':   return (int(a[2],0)<<20)|(reg(a[1])<<15)|(2<<12)|(reg(a[0])<<7)|0x03
    if op=='sw':
        imm=int(a[2],0); imm&=0xfff
        return ((imm>>5)<<25)|(reg(a[0])<<20)|(reg(a[1])<<15)|(2<<12)|((imm&0x1f)<<7)|0x23
    if op in ('beq','bne','blt','bge'):
        imm=int(a[2],0); f3={'beq':0,'bne':1,'blt':4,'bge':5}[op]
        hi=(imm>>12)&1; lo=imm&0xfff
        return (hi<<31)|(((lo>>5)&0x3f)<<25)|(reg(a[1])<<20)|(reg(a[0])<<15)|(f3<<12)|(((lo>>1)&0xf)<<8)|(((lo>>11)&1)<<7)|0x63
    if op=='lui': return ((int(a[1],0)&0xfffff)<<12)|(reg(a[0])<<7)|0x37
    if op=='jal': return 0x6f
    raise Exception(op)
src=[l.split('#')[0].strip() for l in open(sys.argv[1]) if l.split('#')[0].strip()]
labels={}; pc=0; out=[]
for l in src:
    if l.endswith(':'): labels[l[:-1]]=pc*4; continue
    out.append(l); pc+=1
words=[]
addr=0
for l in out:
    p=l.replace(',',' ').split()
    op=p[0]; a=p[1:]
    if op in ('beq','bne','blt','bge') and a[-1] in labels: a[-1]=str(labels[a[-1]]-addr)
    addr+=4
    words.append(enc(op,a))
open(sys.argv[2],'w').write('\n'.join('%08x'%(w&0xFFFFFFFF) for w in words)+'\n')
print('words',len(words))
