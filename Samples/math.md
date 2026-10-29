# 数式の確認用

文の中の数式：円の面積は $S = \pi r^2$、二次方程式の解は $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$ です。添え字 $a_1 + b_1$ が斜体にならないこと。

GitHub の書き方 $`\sqrt{x^2 + y^2}`$ も使えます。

金額は数式にしない：$5 と $10、$100〜$200。`$code$` と \$x$ もそのまま。

## 表示用の数式（`$$` の行で囲む）

$$
\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
$$

行の中の $$\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$$ も表示用になります。

## ```math のコードブロック

```math
\begin{pmatrix} a & b \\ c & d \end{pmatrix}
\begin{pmatrix} x \\ y \end{pmatrix}
=
\begin{pmatrix} ax + by \\ cx + dy \end{pmatrix}
```

## 表の中

| 名前 | 式 |
|---|---|
| 絶対値 | $\lvert x \rvert$ と $|y|$ |
| 太字 | $\mathbf{v} * 2$ |

## 書き方の誤り

$\frac{1}{$ は赤い文字で元の式を出します。

> 引用の中：
> $$
> e^{i\pi} + 1 = 0
> $$
