# =============================================================================
# export_weights_hls.py — .pth → weights_hls.h (Q15.16, 배포본 형식)
#
# 형식 검증 완료: final_res_bnn_ema.pth 로 생성 시 배포본
# (vitis code/A4/hello_world/src/weights_hls.h, 446,808 bytes)과
# byte 단위 100% 일치 확인됨.
#
# 핵심 규칙 (검증으로 확정):
#   - float32 연산 그대로 ×65536 후 truncation (round 아님!)
#   - v_inv = 1/sqrt(running_var + 1e-5), float32
#   - alpha = mean(|w|) per out-channel, float32
#   - binary packing: w > 0 → bit 1, 32ch per uint32, 0x%08x
#   - 줄바꿈 CRLF(\r\n), 마지막 #endif 뒤 개행 없음
#
# 사용법 (인자 없이 실행하면 E:\final 레이아웃 기준):
#   python export_weights_hls.py
#   python export_weights_hls.py --pth E:/final/final_res_bnn_ema.pth --ref 기존weights_hls.h  # 자가검증
# =============================================================================
import argparse
import numpy as np
import torch

S = np.float32(65536)
EPS = np.float32(1e-5)

def q(x):
    """float32 × 65536 → truncation (배포본과 동일)"""
    return (np.asarray(x, dtype=np.float32) * S).astype(np.int64)

def arr_int(name, vals):
    return f"const int {name}[] = {{ {', '.join(map(str, vals.tolist()))} }};"

def arr_hex(name, vals):
    return f"const unsigned int {name}[] = {{ {', '.join(vals)} }};"

def pack_bin(w, in_ch):
    """3×3 binary conv 가중치 32bit 패킹 (w>0 → bit=1)"""
    out = []
    for o in range(w.shape[0]):
        for h in range(3):
            for wi in range(3):
                for i_s in range(0, in_ch, 32):
                    v = 0
                    for bit in range(32):
                        if w[o, i_s + bit, h, wi] > 0:
                            v |= (1 << bit)
                    out.append(f"0x{v:08x}")
    return out

def export(pth_path, out_path):
    sd = {k: v.numpy() if hasattr(v, 'numpy') else v
          for k, v in torch.load(pth_path, map_location='cpu').items()}

    def bn_lines(pfx, key):
        g, b = sd[key + '.weight'], sd[key + '.bias']
        m, v = sd[key + '.running_mean'], sd[key + '.running_var']
        v_inv = np.float32(1.0) / np.sqrt(v.astype(np.float32) + EPS)
        return [arr_int(pfx + "_w", q(g)), arr_int(pfx + "_b", q(b)),
                arr_int(pfx + "_m", q(m)), arr_int(pfx + "_v_inv", q(v_inv))]

    L = ["#ifndef WEIGHTS_HLS_H", "#define WEIGHTS_HLS_H", ""]
    L.append(arr_int("conv1_w", q(sd['conv1.weight'].flatten())))
    L += bn_lines("bn1", "bn1")
    L.append("")

    ics = [32, 64, 128]
    for i in range(3):
        w = sd[f'bconv{i+1}.weight']
        L.append(arr_hex(f"bconv{i+1}_w", pack_bin(w, ics[i])))
        L.append(arr_int(f"shortcut{i+1}_w", q(sd[f'shortcut{i+1}.weight'].flatten())))
        alpha = np.mean(np.abs(w.astype(np.float32)), axis=(1, 2, 3), dtype=np.float32)
        L.append(arr_int(f"bnn{i+1}_alpha", q(alpha)))
        L += bn_lines(f"bn{i+2}", f"bn{i+2}")
        L.append("")

    L.append(arr_int("head_w", q(sd['head.weight'].flatten())))
    L.append(f"const int head_b = {int(np.float32(sd['head.bias'].flatten()[0]) * S)};")
    L.append("#endif")

    data = "\r\n".join(L).encode()
    with open(out_path, "wb") as f:
        f.write(data)
    print(f"[OK] {out_path} 생성 ({len(data):,} bytes)")

    # 배열 크기 검증 (prompt_retrain.md 규격)
    expected = {'conv1_w': 1568, 'bconv1_w': 576, 'shortcut1_w': 2048, 'bnn1_alpha': 64,
                'bconv2_w': 2304, 'shortcut2_w': 8192, 'bnn2_alpha': 128,
                'bconv3_w': 9216, 'shortcut3_w': 32768, 'bnn3_alpha': 256, 'head_w': 256}
    import re as _re
    txt = data.decode()
    ok = True
    for name, n in expected.items():
        m = _re.search(rf'{name}\[\] = \{{([^}}]*)\}}', txt)
        cnt = len(m.group(1).split(','))
        if cnt != n:
            print(f"[ERROR] {name}: {cnt} != {n}"); ok = False
    print("[OK] 모든 배열 크기 규격 일치" if ok else "[FAIL] 크기 불일치 — 사용 금지")
    return data

def main():
    BASE = "E:/final"
    ap = argparse.ArgumentParser()
    ap.add_argument("--pth", default=f"{BASE}/training code/final_res_bnn_pcam.pth")
    ap.add_argument("--out", default=f"{BASE}/training code/weights_hls.h")
    ap.add_argument("--ref", default=None, help="기존 헤더와 byte 비교 (자가검증용)")
    args = ap.parse_args()

    data = export(args.pth, args.out)
    if args.ref:
        ref = open(args.ref, "rb").read()
        print("[검증] " + ("배포본과 100% 일치" if ref == data else
                          f"불일치 (ref {len(ref):,} vs gen {len(data):,} bytes)"))

if __name__ == "__main__":
    main()
