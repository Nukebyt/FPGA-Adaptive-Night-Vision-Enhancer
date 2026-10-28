"""Baseline enhancers the engine is compared against (roadmap task 2.2)."""
import cv2
import numpy as np


def gamma_correct(img_u8, gamma=0.45, gain=1.0):
    x = np.clip(np.asarray(img_u8, np.float64) / 255.0 * gain, 0.0, 1.0)
    return np.clip(np.rint(255.0 * x ** gamma), 0, 255).astype(np.uint8)


def hist_eq(img_u8):
    return cv2.equalizeHist(np.asarray(img_u8, np.uint8))


def clahe(img_u8, clip=2.0, tiles=8):
    return cv2.createCLAHE(clipLimit=clip, tileGridSize=(tiles, tiles)).apply(np.asarray(img_u8, np.uint8))
